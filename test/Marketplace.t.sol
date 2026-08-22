// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Marketplace} from "../src/Marketplace.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";

contract MarketplaceTest is Test {
    Marketplace internal m;
    MockERC20 internal usdc;

    address internal owner = address(this);
    address internal feeSink = address(0xFEE);
    address internal seller;
    uint256 internal sellerPk;
    address internal buyer = address(0xB0B);
    address internal mod1 = address(0xA1);
    address internal mod2 = address(0xA2);
    address internal mod3 = address(0xA3);

    uint256 internal constant PRICE = 100e6;

    function setUp() public {
        sellerPk = 0xA11CE;
        seller = vm.addr(sellerPk);

        usdc = new MockERC20("USD Coin", "USDC");
        m = new Marketplace(owner, feeSink, 100, 0); // 1% cancel fee, no verdict delay
        m.setAllowedToken(address(usdc), true);
        m.addModerator(mod1);
        m.addModerator(mod2);
        m.addModerator(mod3);

        usdc.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdc.approve(address(m), type(uint256).max);
    }

    function _offer() internal returns (uint256 id) {
        vm.prank(seller);
        id = m.createOffer(address(usdc), PRICE, 1 days, 500, 0, keccak256("meta"), "QmCid");
    }

    function testHappyPath() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        uint256 pid = m.purchase(offerId);

        assertEq(usdc.balanceOf(address(m)), PRICE);

        vm.prank(buyer);
        m.confirmReceipt(pid);

        uint256 fee = (PRICE * 500) / 10_000;
        assertEq(usdc.balanceOf(feeSink), fee);
        assertEq(usdc.balanceOf(seller), PRICE - fee);
        assertEq(usdc.balanceOf(address(m)), 0);
    }

    function testCannotPurchaseTwice() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        m.purchase(offerId);
        vm.prank(buyer);
        vm.expectRevert(Marketplace.OfferAlreadyPurchased.selector);
        m.purchase(offerId);
    }

    function testCannotPurchaseExpiredListing() public {
        vm.prank(seller);
        uint256 offerId =
            m.createOffer(address(usdc), PRICE, 1 days, 500, uint64(block.timestamp + 10), keccak256("m"), "cid");
        vm.warp(block.timestamp + 11);
        vm.prank(buyer);
        vm.expectRevert(Marketplace.OfferExpired.selector);
        m.purchase(offerId);
    }

    function testRefundExpiredGoesToBuyer() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        uint256 pid = m.purchase(offerId);
        vm.warp(block.timestamp + 1 days);
        m.refundExpired(pid);
        assertEq(usdc.balanceOf(buyer), 1_000e6);
        assertEq(usdc.balanceOf(feeSink), 0);
    }

    function testSellerCancelTakesNetworkFee() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        uint256 pid = m.purchase(offerId);
        vm.prank(seller);
        m.sellerCancel(pid);
        uint256 penalty = (PRICE * 100) / 10_000;
        assertEq(usdc.balanceOf(feeSink), penalty);
        assertEq(usdc.balanceOf(buyer), 1_000e6 - penalty);
    }

    function testSellerDisputeBlocksAutoRefund() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        uint256 pid = m.purchase(offerId);
        vm.prank(seller);
        m.openDispute(pid, keccak256("proof"));
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(Marketplace.BadState.selector);
        m.refundExpired(pid);
    }

    function testModeratorMajorityPaysSeller() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        uint256 pid = m.purchase(offerId);
        vm.prank(buyer);
        m.openDispute(pid, keccak256("chat"));

        vm.prank(mod1);
        m.vote(pid, true);
        vm.prank(mod2);
        m.vote(pid, true);

        m.executeVerdict(pid);
        uint256 fee = (PRICE * 500) / 10_000;
        assertEq(usdc.balanceOf(seller), PRICE - fee);
        assertEq(usdc.balanceOf(feeSink), fee);
    }

    function testModeratorMajorityRefundsBuyer() public {
        uint256 offerId = _offer();
        vm.prank(buyer);
        uint256 pid = m.purchase(offerId);
        vm.prank(seller);
        m.openDispute(pid, keccak256("undelivered"));

        vm.prank(mod1);
        m.vote(pid, false);
        vm.prank(mod2);
        m.vote(pid, false);

        m.executeVerdict(pid);
        assertEq(usdc.balanceOf(buyer), 1_000e6);
    }

    function testFeeBounds() public {
        vm.prank(seller);
        vm.expectRevert(Marketplace.InvalidFee.selector);
        m.createOffer(address(usdc), PRICE, 1 days, 9, 0, bytes32(0), "x");
        vm.prank(seller);
        vm.expectRevert(Marketplace.InvalidFee.selector);
        m.createOffer(address(usdc), PRICE, 1 days, 2001, 0, bytes32(0), "x");
    }

    function testCreateOfferWithSig() public {
        uint256 nonce = m.nonces(seller);
        bytes32 structHash = keccak256(
            abi.encode(
                m.OFFER_TYPEHASH(),
                seller,
                address(usdc),
                PRICE,
                uint32(1 days),
                uint16(500),
                uint64(0),
                keccak256("meta"),
                keccak256(bytes("QmCid")),
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", m.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 id = m.createOfferWithSig(
            seller, address(usdc), PRICE, 1 days, 500, 0, keccak256("meta"), "QmCid", sig
        );
        (address sAddr,,,,,,,, bool active,) = _offerTuple(id);
        assertEq(sAddr, seller);
        assertTrue(active);
    }

    function _offerTuple(uint256 id)
        internal
        view
        returns (address, address, uint256, uint32, uint16, uint64, bytes32, string memory, bool, bool)
    {
        return m.offers(id);
    }
}
