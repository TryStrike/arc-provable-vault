// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProvableVault} from "../src/ProvableVault.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external virtual returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// Like USDT: transfer and approve return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transfer(address to, uint256 a) external {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }
}

/// Returns false instead of reverting.
contract FalseToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

contract MockMessenger {
    struct Call {
        uint256 amount;
        uint32 domain;
        bytes32 mintRecipient;
        address burnToken;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinality;
        address caller;
    }

    Call[] public calls;
    // set to make the messenger call back into the vault while it is mid-burn
    ProvableVault public reenterVault;
    address public reenterToken;
    bool public reenterOk;
    bytes public reenterRevert;

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function arm(ProvableVault v, address token) external {
        reenterVault = v;
        reenterToken = token;
    }

    function depositForBurn(uint256 a, uint32 d, bytes32 r, address t, bytes32 dc, uint256 mf, uint32 mfin) external {
        calls.push(Call(a, d, r, t, dc, mf, mfin, msg.sender));
        if (address(reenterVault) != address(0)) {
            try reenterVault.payout(reenterToken, address(this), 1, bytes32(0)) {
                reenterOk = true;
            } catch (bytes memory err) {
                reenterRevert = err;
            }
        }
    }
}

/// A token that calls back into the vault from inside `transfer`.
/// It is set as the operator so the callback passes the role check and only the caps can stop it.
contract ReentrantToken is MockERC20 {
    ProvableVault public vault;
    bool public armed;
    bool public reenterOk;
    bytes public reenterRevert;

    function arm(ProvableVault v) external {
        vault = v;
        armed = true;
    }

    function transfer(address to, uint256 a) external override returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        if (armed) {
            armed = false;
            try vault.payout(address(this), to, 1, bytes32(0)) {
                reenterOk = true;
            } catch (bytes memory err) {
                reenterRevert = err;
            }
        }
        return true;
    }

    function callVault(bytes calldata data) external {
        (bool ok,) = address(vault).call(data);
        require(ok, "vault call failed");
    }
}

contract ProvableVaultTest is Test {
    event Payout(address indexed token, address indexed to, uint256 amount, bytes32 indexed ref);
    event CrossChainPayout(
        address token,
        bytes32 indexed mintRecipient,
        uint32 indexed domain,
        uint256 amount,
        uint256 maxFee,
        bytes32 indexed ref
    );
    event BatchCommitted(uint256 indexed epoch, bytes32 root, uint256 count);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event CapSet(address indexed token, uint128 perTx, uint128 perDay);
    event OperatorSet(address indexed operator);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    ProvableVault internal t;
    MockERC20 internal usdc;
    MockERC20 internal eurc;
    MockERC20 internal other;
    MockMessenger internal msgr;

    address internal owner = address(0xA11CE);
    address internal operator = address(0xB0B);
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);
    address internal outsider = address(0xDEAD);

    uint128 internal constant PER_TX = 100e6;
    uint128 internal constant PER_DAY = 250e6;
    bytes32 internal constant REF = keccak256("ref");

    function _deploy() internal returns (ProvableVault) {
        return new ProvableVault(address(msgr), owner, operator);
    }

    function setUp() public {
        vm.warp(10 days);
        usdc = new MockERC20();
        eurc = new MockERC20();
        other = new MockERC20();
        msgr = new MockMessenger();
        t = _deploy();
        usdc.mint(address(t), 10_000e6);
        eurc.mint(address(t), 10_000e6);
        other.mint(address(t), 10_000e6);
        vm.startPrank(owner);
        t.setCap(address(usdc), PER_TX, PER_DAY);
        t.setCap(address(eurc), PER_TX, PER_DAY);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- constructor
    function test_ConstructorState() public view {
        assertEq(t.owner(), owner);
        assertEq(t.operator(), operator);
        assertEq(address(t.tokenMessenger()), address(msgr));
        assertEq(t.pendingOwner(), address(0));
        assertFalse(t.paused());
    }

    function test_ConstructorEmitsEvents() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(address(0), owner);
        vm.expectEmit(true, false, false, false);
        emit OperatorSet(operator);
        _deploy();
    }

    function test_ConstructorZeroAddressReverts() public {
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        new ProvableVault(address(0), owner, operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        new ProvableVault(address(msgr), address(0), operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        new ProvableVault(address(msgr), owner, address(0));
    }

    function test_OwnerIsOwnerArgNotDeployer() public {
        address deployer = address(0xDE91);
        vm.prank(deployer);
        ProvableVault t2 = _deploy();
        assertEq(t2.owner(), owner);
        assertTrue(t2.owner() != deployer);
        // the deployer has no owner rights
        vm.prank(deployer);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t2.setCap(address(usdc), 1, 1);
        // the owner does
        vm.prank(owner);
        t2.setCap(address(usdc), 1, 1);
    }

    function test_OwnerAndOperatorMayBeTheSameAddress() public {
        ProvableVault t2 = new ProvableVault(address(msgr), operator, operator);
        assertEq(t2.owner(), operator);
        assertEq(t2.operator(), operator);
        vm.prank(operator);
        t2.pause();
        vm.prank(operator);
        t2.unpause();
        assertFalse(t2.paused());
    }

    // ---------------------------------------------------------------- payout
    function test_PayoutHappyPathEmitsAndTransfers() public {
        vm.expectEmit(true, true, true, true);
        emit Payout(address(usdc), alice, 40e6, REF);
        vm.prank(operator);
        t.payout(address(usdc), alice, 40e6, REF);
        assertEq(usdc.balanceOf(alice), 40e6);
        assertEq(usdc.balanceOf(address(t)), 10_000e6 - 40e6);
        assertEq(t.remainingToday(address(usdc)), PER_DAY - 40e6);
    }

    function test_PayoutEurcWorks() public {
        vm.prank(operator);
        t.payout(address(eurc), alice, PER_TX, REF);
        assertEq(eurc.balanceOf(alice), PER_TX);
    }

    function test_PayoutAtPerTxCapOk() public {
        vm.prank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        assertEq(usdc.balanceOf(alice), PER_TX);
    }

    function test_PayoutOverPerTxReverts() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(PER_TX) + 1, uint256(PER_TX))
        );
        t.payout(address(usdc), alice, uint256(PER_TX) + 1, REF);
    }

    function test_PayoutOverPerDayReverts() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        // 200 used, 50 remaining
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(PER_TX), uint256(50e6)));
        t.payout(address(usdc), alice, PER_TX, REF);
        // exactly remaining is ok
        t.payout(address(usdc), alice, 50e6, REF);
        assertEq(t.remainingToday(address(usdc)), 0);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);
        vm.stopPrank();
    }

    function test_PerDayCapIsPerToken() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, 50e6, REF);
        // eurc untouched
        t.payout(address(eurc), alice, PER_TX, REF);
        vm.stopPrank();
        assertEq(t.remainingToday(address(eurc)), PER_DAY - PER_TX);
    }

    function test_CapResetsNextDay() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, 50e6, REF);
        assertEq(t.remainingToday(address(usdc)), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
        t.payout(address(usdc), alice, PER_TX, REF);
        assertEq(t.remainingToday(address(usdc)), PER_DAY - PER_TX);
        vm.stopPrank();
    }

    function test_NoCapSetPaysNothing() public {
        // fresh vault: caps default to 0
        ProvableVault t2 = _deploy();
        usdc.mint(address(t2), 1_000e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t2.payout(address(usdc), alice, 1, REF);
        assertEq(t2.remainingToday(address(usdc)), 0);
    }

    function test_PayoutTokenWithoutCapReverts() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(other), alice, 1, REF);
    }

    function test_PayoutAnyTokenOnceCapIsSet() public {
        vm.prank(owner);
        t.setCap(address(other), 10, 20);
        vm.prank(operator);
        t.payout(address(other), alice, 10, REF);
        assertEq(other.balanceOf(alice), 10);
    }

    function test_PayoutZeroAmountReverts() public {
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAmount.selector);
        t.payout(address(usdc), alice, 0, REF);
    }

    function test_PayoutZeroRecipientReverts() public {
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.payout(address(usdc), address(0), 1, REF);
    }

    function test_FailedPayoutDoesNotConsumeCap() public {
        vm.startPrank(operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.payout(address(usdc), address(0), 10e6, REF);
        vm.stopPrank();
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
    }

    function test_PayoutShortBalanceRevertsAndKeepsCap() public {
        vm.prank(owner);
        t.sweep(address(usdc), bob, 10_000e6 - 10e6);
        vm.prank(operator);
        vm.expectRevert(bytes("bal"));
        t.payout(address(usdc), alice, 11e6, REF);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
    }

    function test_PayoutNoReturnTokenWorks() public {
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(address(t), 1_000e6);
        vm.prank(owner);
        t.setCap(address(usdt), PER_TX, PER_DAY);
        vm.prank(operator);
        t.payout(address(usdt), alice, 5e6, REF);
        assertEq(usdt.balanceOf(alice), 5e6);
        vm.prank(owner);
        t.sweep(address(usdt), bob, 7e6);
        assertEq(usdt.balanceOf(bob), 7e6);
    }

    function test_PayoutFalseReturnRevertsAndKeepsCap() public {
        FalseToken ft = new FalseToken();
        vm.prank(owner);
        t.setCap(address(ft), PER_TX, PER_DAY);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.TransferFailed.selector);
        t.payout(address(ft), alice, 1, REF);
        assertEq(t.remainingToday(address(ft)), PER_DAY);
    }

    function test_PayoutToNonContractTokenReverts() public {
        address eoa = address(0x1234);
        vm.prank(owner);
        t.setCap(eoa, PER_TX, PER_DAY);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.TransferFailed.selector);
        t.payout(eoa, alice, 1, REF);
    }

    // ---------------------------------------------------------------- cap boundaries
    function test_PerTxBoundaryExact() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX - 1, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        vm.expectRevert(
            abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(PER_TX) + 1, uint256(PER_TX))
        );
        t.payout(address(usdc), alice, uint256(PER_TX) + 1, REF);
        vm.stopPrank();
    }

    function test_PerDayBoundaryAtLastSecondThenRollover() public {
        uint256 endOfDay = 11 days - 1;
        vm.warp(endOfDay);
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, 50e6, REF);
        assertEq(t.remainingToday(address(usdc)), 0);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);

        // one second later is a new UTC day with the full cap again
        vm.warp(11 days);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, 50e6, REF);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 2 * uint256(PER_DAY));
    }

    function test_SkippedDaysStillGiveFullCap() public {
        vm.prank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        vm.warp(block.timestamp + 30 days);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
    }

    function test_SpendWithinSameDayAccumulatesAcrossTimes() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, 60e6, REF);
        vm.warp(block.timestamp + 12 hours);
        t.payout(address(usdc), alice, 60e6, REF);
        assertEq(t.remainingToday(address(usdc)), PER_DAY - 120e6);
        vm.stopPrank();
    }

    function test_LoweringPerDayBelowUsedBlocksPayouts() public {
        vm.prank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        vm.prank(owner);
        t.setCap(address(usdc), PER_TX, 50e6);
        assertEq(t.remainingToday(address(usdc)), 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);
    }

    function test_RaisingCapMidDayAddsHeadroom() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, 50e6, REF);
        vm.stopPrank();
        vm.prank(owner);
        t.setCap(address(usdc), PER_TX, 400e6);
        assertEq(t.remainingToday(address(usdc)), 150e6);
    }

    function test_PerDayBelowPerTxIsTheRealLimit() public {
        vm.prank(owner);
        t.setCap(address(usdc), 100e6, 30e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(31e6), uint256(30e6)));
        t.payout(address(usdc), alice, 31e6, REF);
    }

    function test_ZeroingEitherCapStopsPayouts() public {
        vm.prank(owner);
        t.setCap(address(usdc), 0, PER_DAY);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);

        vm.prank(owner);
        t.setCap(address(usdc), PER_TX, 0);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);
    }

    function test_MaxCapsDoNotOverflow() public {
        vm.prank(owner);
        t.setCap(address(usdc), type(uint128).max, type(uint128).max);
        usdc.mint(address(t), type(uint128).max);
        vm.startPrank(operator);
        t.payout(address(usdc), alice, type(uint128).max, REF);
        assertEq(t.remainingToday(address(usdc)), 0);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payout(address(usdc), alice, 1, REF);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- payoutBatch
    function _batch(uint256 a, uint256 b, uint256 c)
        internal
        view
        returns (address[] memory to, uint256[] memory amts, bytes32[] memory refs)
    {
        to = new address[](3);
        amts = new uint256[](3);
        refs = new bytes32[](3);
        to[0] = alice;
        to[1] = bob;
        to[2] = alice;
        amts[0] = a;
        amts[1] = b;
        amts[2] = c;
        refs[0] = keccak256("r0");
        refs[1] = keccak256("r1");
        refs[2] = keccak256("r2");
    }

    function test_BatchPaysAndEmitsPerRecipient() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(10e6, 20e6, 30e6);
        for (uint256 i; i < 3; i++) {
            vm.expectEmit(true, true, true, true);
            emit Payout(address(usdc), to[i], amts[i], refs[i]);
        }
        vm.prank(operator);
        t.payoutBatch(address(usdc), to, amts, refs);
        assertEq(usdc.balanceOf(alice), 40e6);
        assertEq(usdc.balanceOf(bob), 20e6);
        assertEq(t.remainingToday(address(usdc)), PER_DAY - 60e6);
    }

    function test_BatchTotalAtPerTxCapOk() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(50e6, 30e6, 20e6);
        vm.prank(operator);
        t.payoutBatch(address(usdc), to, amts, refs);
        assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), PER_TX);
    }

    function test_BatchTotalCheckedAgainstPerTx() public {
        // each item under perTx but total 180 > 100
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(60e6, 60e6, 60e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(180e6), uint256(PER_TX)));
        t.payoutBatch(address(usdc), to, amts, refs);
        assertEq(usdc.balanceOf(alice), 0);
    }

    function test_BatchTotalCheckedAgainstPerDay() public {
        vm.startPrank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        t.payout(address(usdc), alice, PER_TX, REF);
        // 50 remaining; batch total 60
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(20e6, 20e6, 20e6);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(60e6), uint256(50e6)));
        t.payoutBatch(address(usdc), to, amts, refs);
        vm.stopPrank();
    }

    function test_BatchLengthMismatchReverts() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(1, 2, 3);
        uint256[] memory shortAmts = new uint256[](2);
        bytes32[] memory shortRefs = new bytes32[](2);
        vm.startPrank(operator);
        vm.expectRevert(ProvableVault.LengthMismatch.selector);
        t.payoutBatch(address(usdc), to, shortAmts, refs);
        vm.expectRevert(ProvableVault.LengthMismatch.selector);
        t.payoutBatch(address(usdc), to, amts, shortRefs);
        vm.stopPrank();
    }

    function test_BatchEmptyReverts() public {
        address[] memory to = new address[](0);
        uint256[] memory amts = new uint256[](0);
        bytes32[] memory refs = new bytes32[](0);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.LengthMismatch.selector);
        t.payoutBatch(address(usdc), to, amts, refs);
    }

    function test_BatchTokenWithoutCapReverts() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(1, 2, 3);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(6), uint256(0)));
        t.payoutBatch(address(other), to, amts, refs);

        ProvableVault t2 = _deploy();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(6), uint256(0)));
        t2.payoutBatch(address(usdc), to, amts, refs);
    }

    function test_BatchZeroTotalAndZeroRecipientRevert() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(0, 0, 0);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAmount.selector);
        t.payoutBatch(address(usdc), to, amts, refs);

        (to, amts, refs) = _batch(1, 2, 3);
        to[1] = address(0);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.payoutBatch(address(usdc), to, amts, refs);
    }

    function test_BatchIsAtomicOnLateFailure() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(1, 2, 3);
        to[2] = address(0);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.payoutBatch(address(usdc), to, amts, refs);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
    }

    function test_BatchZeroItemAmongOthersIsAllowed() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(0, 5, 0);
        vm.prank(operator);
        t.payoutBatch(address(usdc), to, amts, refs);
        assertEq(usdc.balanceOf(bob), 5);
    }

    function test_BatchAcrossDayRollover() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(30e6, 30e6, 30e6);
        vm.startPrank(operator);
        t.payoutBatch(address(usdc), to, amts, refs);
        t.payoutBatch(address(usdc), to, amts, refs);
        // 180 used, 70 left, 90 asked
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(90e6), uint256(70e6)));
        t.payoutBatch(address(usdc), to, amts, refs);
        vm.warp(block.timestamp + 1 days);
        t.payoutBatch(address(usdc), to, amts, refs);
        vm.stopPrank();
        assertEq(t.remainingToday(address(usdc)), PER_DAY - 90e6);
    }

    // ---------------------------------------------------------------- payoutCrossChain
    function test_CrossChainCallsMessengerWithCorrectArgs() public {
        bytes32 mr = bytes32(uint256(uint160(alice)));
        vm.expectEmit(true, true, true, true);
        emit CrossChainPayout(address(usdc), mr, 6, 50e6, 1e5, REF);
        vm.prank(operator);
        t.payoutCrossChain(address(usdc), mr, 6, 50e6, 1e5, 1000, REF);

        assertEq(msgr.callCount(), 1);
        (
            uint256 amount,
            uint32 domain,
            bytes32 mintRecipient,
            address burnToken,
            bytes32 destCaller,
            uint256 maxFee,
            uint32 minFinality,
            address caller
        ) = msgr.calls(0);
        assertEq(amount, 50e6);
        assertEq(uint256(domain), 6);
        assertEq(mintRecipient, mr);
        assertEq(burnToken, address(usdc));
        assertEq(destCaller, bytes32(0));
        assertEq(maxFee, 1e5);
        assertEq(uint256(minFinality), 1000);
        assertEq(caller, address(t));
        // approval is exactly the amount; mock pulls nothing
        assertEq(usdc.allowance(address(t), address(msgr)), 50e6);
        assertEq(usdc.balanceOf(address(t)), 10_000e6);
    }

    function test_CrossChainApprovalIsExactPerBurn() public {
        bytes32 mr = bytes32(uint256(1));
        vm.startPrank(operator);
        t.payoutCrossChain(address(usdc), mr, 6, 40e6, 0, 2000, REF);
        assertEq(usdc.allowance(address(t), address(msgr)), 40e6);
        // the next burn replaces the approval, it never stacks
        t.payoutCrossChain(address(usdc), mr, 6, 7e6, 0, 2000, REF);
        assertEq(usdc.allowance(address(t), address(msgr)), 7e6);
        vm.stopPrank();
        assertEq(msgr.callCount(), 2);
    }

    function test_CrossChainAnyCappedTokenApprovesThatToken() public {
        vm.prank(operator);
        t.payoutCrossChain(address(eurc), bytes32(uint256(1)), 1, 3e6, 0, 1000, REF);
        (,,, address burnToken,,,,) = msgr.calls(0);
        assertEq(burnToken, address(eurc));
        assertEq(eurc.allowance(address(t), address(msgr)), 3e6);
        assertEq(usdc.allowance(address(t), address(msgr)), 0);
    }

    function test_CrossChainCountsAgainstCaps() public {
        bytes32 mr = bytes32(uint256(1));
        vm.startPrank(operator);
        t.payoutCrossChain(address(usdc), mr, 1, PER_TX, 0, 1000, REF);
        assertEq(t.remainingToday(address(usdc)), PER_DAY - PER_TX);
        t.payout(address(usdc), alice, PER_TX, REF);
        // 200 used -> 50 remaining
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(60e6), uint256(50e6)));
        t.payoutCrossChain(address(usdc), mr, 1, 60e6, 0, 1000, REF);
        vm.expectRevert(
            abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(PER_TX) + 1, uint256(PER_TX))
        );
        t.payoutCrossChain(address(usdc), mr, 1, uint256(PER_TX) + 1, 0, 1000, REF);
        vm.stopPrank();
        assertEq(msgr.callCount(), 1);
    }

    function test_CrossChainTokenWithoutCapReverts() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        t.payoutCrossChain(address(other), bytes32(uint256(1)), 1, 1, 0, 1000, REF);
    }

    function test_CrossChainZeroMintRecipientReverts() public {
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.payoutCrossChain(address(usdc), bytes32(0), 1, 1e6, 0, 1000, REF);
    }

    function test_CrossChainZeroAmountReverts() public {
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroAmount.selector);
        t.payoutCrossChain(address(usdc), bytes32(uint256(1)), 1, 0, 0, 1000, REF);
    }

    function test_CrossChainApproveFalseReverts() public {
        FalseToken ft = new FalseToken();
        vm.prank(owner);
        t.setCap(address(ft), PER_TX, PER_DAY);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.TransferFailed.selector);
        t.payoutCrossChain(address(ft), bytes32(uint256(1)), 1, 1, 0, 1000, REF);
        assertEq(msgr.callCount(), 0);
        assertEq(t.remainingToday(address(ft)), PER_DAY);
    }

    function test_CrossChainNoReturnTokenWorks() public {
        NoReturnToken usdt = new NoReturnToken();
        vm.prank(owner);
        t.setCap(address(usdt), PER_TX, PER_DAY);
        vm.prank(operator);
        t.payoutCrossChain(address(usdt), bytes32(uint256(1)), 1, 9, 0, 1000, REF);
        assertEq(usdt.allowance(address(t), address(msgr)), 9);
    }

    // ---------------------------------------------------------------- batches (Merkle commits)
    function _h(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// Builds every level of a sorted-pair tree. An odd node is carried up unchanged.
    function _levels(bytes32[] memory leaves) internal pure returns (bytes32[][] memory lv) {
        uint256 h = 1;
        for (uint256 n = leaves.length; n > 1; n = (n + 1) / 2) {
            ++h;
        }
        lv = new bytes32[][](h);
        lv[0] = leaves;
        for (uint256 l = 1; l < h; ++l) {
            bytes32[] memory prev = lv[l - 1];
            bytes32[] memory cur = new bytes32[]((prev.length + 1) / 2);
            for (uint256 i; i < cur.length; ++i) {
                cur[i] = 2 * i + 1 < prev.length ? _h(prev[2 * i], prev[2 * i + 1]) : prev[2 * i];
            }
            lv[l] = cur;
        }
    }

    function _proof(bytes32[][] memory lv, uint256 idx) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](lv.length);
        uint256 c;
        for (uint256 l; l + 1 < lv.length; ++l) {
            uint256 sib = idx ^ 1;
            if (sib < lv[l].length) p[c++] = lv[l][sib];
            idx /= 2;
        }
        assembly {
            mstore(p, c)
        }
    }

    function _leaves(uint256 seed, uint256 n) internal pure returns (bytes32[] memory l) {
        l = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            l[i] = keccak256(abi.encode(seed, i));
        }
    }

    function test_CommitBatchWriteOnceAndEmits() public {
        bytes32 root = keccak256("root");
        vm.expectEmit(true, false, false, true);
        emit BatchCommitted(7, root, 4);
        vm.prank(operator);
        t.commitBatch(7, root, 4);
        assertEq(t.batchRoots(7), root);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.RootAlreadyCommitted.selector, uint256(7)));
        t.commitBatch(7, keccak256("other"), 1);
        assertEq(t.batchRoots(7), root);

        // different epoch fine
        vm.prank(operator);
        t.commitBatch(8, keccak256("root8"), 1);
    }

    function test_CommitBatchZeroRootReverts() public {
        vm.prank(operator);
        vm.expectRevert(ProvableVault.ZeroRoot.selector);
        t.commitBatch(1, bytes32(0), 0);
        // a rejected zero root leaves the epoch open
        vm.prank(operator);
        t.commitBatch(1, keccak256("root"), 1);
    }

    function test_CommitIsWriteOnceEvenAfterOperatorChange() public {
        vm.prank(operator);
        t.commitBatch(1, keccak256("a"), 1);
        vm.prank(owner);
        t.setOperator(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.RootAlreadyCommitted.selector, uint256(1)));
        t.commitBatch(1, keccak256("b"), 1);
        // not even the owner can rewrite it
        vm.prank(owner);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.commitBatch(1, keccak256("b"), 1);
        assertEq(t.batchRoots(1), keccak256("a"));
    }

    function test_VerifyLeafMerkle4Leaves() public {
        bytes32[4] memory l = [keccak256("l0"), keccak256("l1"), keccak256("l2"), keccak256("l3")];
        bytes32 p01 = _h(l[0], l[1]);
        bytes32 p23 = _h(l[2], l[3]);
        bytes32 root = _h(p01, p23);
        vm.prank(operator);
        t.commitBatch(1, root, 4);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = l[1];
        proof[1] = p23;
        assertTrue(t.verifyLeaf(1, l[0], proof));

        proof[0] = l[0];
        assertTrue(t.verifyLeaf(1, l[1], proof));

        proof[0] = l[3];
        proof[1] = p01;
        assertTrue(t.verifyLeaf(1, l[2], proof));

        proof[0] = l[2];
        assertTrue(t.verifyLeaf(1, l[3], proof));
    }

    function test_VerifyLeafWrongLeafFalse() public {
        bytes32[4] memory l = [keccak256("l0"), keccak256("l1"), keccak256("l2"), keccak256("l3")];
        bytes32 p23 = _h(l[2], l[3]);
        vm.prank(operator);
        t.commitBatch(1, _h(_h(l[0], l[1]), p23), 4);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = l[1];
        proof[1] = p23;
        assertFalse(t.verifyLeaf(1, keccak256("bogus"), proof));
        // right leaf, wrong proof
        proof[0] = l[2];
        assertFalse(t.verifyLeaf(1, l[0], proof));
    }

    function test_VerifyLeafTamperedProofFalse() public {
        bytes32[] memory leaves = _leaves(1, 8);
        bytes32[][] memory lv = _levels(leaves);
        vm.prank(operator);
        t.commitBatch(1, lv[lv.length - 1][0], 8);
        bytes32[] memory proof = _proof(lv, 3);
        assertTrue(t.verifyLeaf(1, leaves[3], proof));
        for (uint256 i; i < proof.length; ++i) {
            bytes32 saved = proof[i];
            proof[i] = bytes32(uint256(saved) ^ 1);
            assertFalse(t.verifyLeaf(1, leaves[3], proof));
            proof[i] = saved;
        }
        // a truncated proof fails, and an extended one fails
        bytes32[] memory shorter = new bytes32[](proof.length - 1);
        for (uint256 i; i < shorter.length; ++i) {
            shorter[i] = proof[i];
        }
        assertFalse(t.verifyLeaf(1, leaves[3], shorter));
        bytes32[] memory longer = new bytes32[](proof.length + 1);
        for (uint256 i; i < proof.length; ++i) {
            longer[i] = proof[i];
        }
        longer[proof.length] = keccak256("extra");
        assertFalse(t.verifyLeaf(1, leaves[3], longer));
    }

    function test_VerifyLeafWrongEpochFalse() public {
        bytes32[] memory leaves = _leaves(2, 4);
        bytes32[][] memory lv = _levels(leaves);
        vm.startPrank(operator);
        t.commitBatch(1, lv[lv.length - 1][0], 4);
        t.commitBatch(2, keccak256("another root"), 1);
        vm.stopPrank();
        bytes32[] memory proof = _proof(lv, 0);
        assertTrue(t.verifyLeaf(1, leaves[0], proof));
        assertFalse(t.verifyLeaf(2, leaves[0], proof));
        assertFalse(t.verifyLeaf(3, leaves[0], proof));
    }

    function test_VerifyLeafUncommittedEpochFalse() public view {
        bytes32[] memory proof = new bytes32[](0);
        // even a zero leaf with empty proof must not verify against an empty root
        assertFalse(t.verifyLeaf(99, bytes32(0), proof));
        assertFalse(t.verifyLeaf(99, keccak256("x"), proof));
    }

    function test_VerifySingleLeafTreeNeedsEmptyProof() public {
        bytes32 leaf = keccak256("only");
        vm.prank(operator);
        t.commitBatch(1, leaf, 1);
        assertTrue(t.verifyLeaf(1, leaf, new bytes32[](0)));
        assertFalse(t.verifyLeaf(1, keccak256("not only"), new bytes32[](0)));
    }

    function test_VerifyWorksWhilePausedAndForAnyone() public {
        bytes32 leaf = keccak256("only");
        vm.prank(operator);
        t.commitBatch(1, leaf, 1);
        vm.prank(owner);
        t.pause();
        vm.prank(outsider);
        assertTrue(t.verifyLeaf(1, leaf, new bytes32[](0)));
    }

    function test_VerifyOddSizedTrees() public {
        for (uint256 n = 1; n <= 9; ++n) {
            bytes32[] memory leaves = _leaves(100 + n, n);
            bytes32[][] memory lv = _levels(leaves);
            vm.prank(operator);
            t.commitBatch(1000 + n, lv[lv.length - 1][0], n);
            for (uint256 i; i < n; ++i) {
                assertTrue(t.verifyLeaf(1000 + n, leaves[i], _proof(lv, i)));
            }
        }
    }

    // ---------------------------------------------------------------- pause
    function test_OperatorAndOwnerCanPause() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(operator);
        vm.prank(operator);
        t.pause();
        assertTrue(t.paused());

        vm.prank(owner);
        t.unpause();
        assertFalse(t.paused());

        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        vm.prank(owner);
        t.pause();
        assertTrue(t.paused());
    }

    function test_OutsiderCannotPause() public {
        vm.prank(outsider);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.pause();
        assertFalse(t.paused());
    }

    function test_OnlyOwnerUnpauses() public {
        vm.prank(operator);
        t.pause();

        vm.prank(operator);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.unpause();
        vm.prank(outsider);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.unpause();
        assertTrue(t.paused());

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        vm.prank(owner);
        t.unpause();
        assertFalse(t.paused());
    }

    function test_PauseIsIdempotent() public {
        vm.startPrank(owner);
        t.pause();
        t.pause();
        vm.stopPrank();
        assertTrue(t.paused());
    }

    function test_FormerOperatorCannotPause() public {
        vm.prank(owner);
        t.setOperator(alice);
        vm.prank(operator);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.pause();
        vm.prank(alice);
        t.pause();
        assertTrue(t.paused());
    }

    function test_OperatorActionsRevertWhilePaused() public {
        vm.prank(owner);
        t.pause();
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(1, 2, 3);
        vm.startPrank(operator);
        vm.expectRevert(ProvableVault.IsPaused.selector);
        t.payout(address(usdc), alice, 1, REF);
        vm.expectRevert(ProvableVault.IsPaused.selector);
        t.payoutBatch(address(usdc), to, amts, refs);
        vm.expectRevert(ProvableVault.IsPaused.selector);
        t.payoutCrossChain(address(usdc), bytes32(uint256(1)), 1, 1, 0, 1000, REF);
        vm.expectRevert(ProvableVault.IsPaused.selector);
        t.commitBatch(1, keccak256("r"), 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 0);

        // after unpause it works again
        vm.prank(owner);
        t.unpause();
        vm.prank(operator);
        t.payout(address(usdc), alice, 1, REF);
        assertEq(usdc.balanceOf(alice), 1);
    }

    function test_OwnerFunctionsStillWorkWhilePaused() public {
        vm.prank(operator);
        t.pause();
        vm.prank(owner);
        t.setCap(address(usdc), 5, 6);
        vm.prank(owner);
        t.sweep(address(usdc), alice, 1);
        assertEq(usdc.balanceOf(alice), 1);
    }

    // ---------------------------------------------------------------- access control
    function test_OperatorCannotCallOwnerFunctions() public {
        vm.startPrank(operator);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.setCap(address(usdc), 1, 1);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.setOperator(alice);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.sweep(address(usdc), alice, 1);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.transferOwnership(alice);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.unpause();
        vm.stopPrank();
    }

    function test_OutsiderCannotCallAnything() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(1, 2, 3);
        vm.startPrank(outsider);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.setCap(address(usdc), 1, 1);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.setOperator(outsider);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.sweep(address(usdc), outsider, 1);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payout(address(usdc), alice, 1, REF);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payoutBatch(address(usdc), to, amts, refs);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payoutCrossChain(address(usdc), bytes32(uint256(1)), 1, 1, 0, 1000, REF);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.commitBatch(1, keccak256("r"), 1);
        vm.stopPrank();
    }

    function test_OwnerCannotCallOperatorFunctions() public {
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(1, 2, 3);
        vm.startPrank(owner);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payout(address(usdc), alice, 1, REF);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payoutBatch(address(usdc), to, amts, refs);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payoutCrossChain(address(usdc), bytes32(uint256(1)), 1, 1, 0, 1000, REF);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.commitBatch(1, keccak256("r"), 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- owner config
    function test_SweepMovesAnyToken() public {
        vm.expectEmit(true, true, false, true);
        emit Swept(address(eurc), bob, 123e6);
        vm.prank(owner);
        t.sweep(address(eurc), bob, 123e6);
        assertEq(eurc.balanceOf(bob), 123e6);
        assertEq(eurc.balanceOf(address(t)), 10_000e6 - 123e6);
        // sweep is not subject to caps
        vm.prank(owner);
        t.sweep(address(usdc), bob, 5_000e6);
        assertEq(usdc.balanceOf(bob), 5_000e6);
        // a token that never had a cap can be rescued too
        vm.prank(owner);
        t.sweep(address(other), bob, 10_000e6);
        assertEq(other.balanceOf(bob), 10_000e6);
    }

    function test_SweepDoesNotTouchCapAccounting() public {
        vm.prank(owner);
        t.sweep(address(usdc), bob, 1_000e6);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
    }

    function test_SweepZeroRecipientReverts() public {
        vm.prank(owner);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.sweep(address(usdc), address(0), 1);
    }

    function test_SweepMoreThanBalanceReverts() public {
        vm.prank(owner);
        vm.expectRevert(bytes("bal"));
        t.sweep(address(usdc), bob, 10_000e6 + 1);
    }

    function test_SetCapEmitsAndStores() public {
        vm.expectEmit(true, false, false, true);
        emit CapSet(address(usdc), 7, 9);
        vm.prank(owner);
        t.setCap(address(usdc), 7, 9);
        (uint128 perTx, uint128 perDay) = t.caps(address(usdc));
        assertEq(uint256(perTx), 7);
        assertEq(uint256(perDay), 9);
        assertEq(t.remainingToday(address(usdc)), 9);
    }

    function test_SetCapAnyTokenAndZeroTokenReverts() public {
        vm.prank(owner);
        t.setCap(address(other), 1, 2);
        (uint128 perTx, uint128 perDay) = t.caps(address(other));
        assertEq(uint256(perTx), 1);
        assertEq(uint256(perDay), 2);
        vm.prank(owner);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.setCap(address(0), 1, 1);
    }

    function test_SetOperatorEmitsAndSwitches() public {
        vm.expectEmit(true, false, false, false);
        emit OperatorSet(alice);
        vm.prank(owner);
        t.setOperator(alice);
        assertEq(t.operator(), alice);

        vm.prank(operator);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payout(address(usdc), bob, 1, REF);
        vm.prank(alice);
        t.payout(address(usdc), bob, 1, REF);
        assertEq(usdc.balanceOf(bob), 1);
    }

    function test_SetOperatorZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.setOperator(address(0));
    }

    function test_OperatorSwapKeepsDailySpend() public {
        vm.prank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        vm.prank(owner);
        t.setOperator(alice);
        // a new operator key does not reset the day's cap
        assertEq(t.remainingToday(address(usdc)), PER_DAY - PER_TX);
    }

    // ---------------------------------------------------------------- ownership
    function test_TwoStepOwnership() public {
        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, alice);
        vm.prank(owner);
        t.transferOwnership(alice);
        assertEq(t.pendingOwner(), alice);
        assertEq(t.owner(), owner);

        vm.prank(bob);
        vm.expectRevert(ProvableVault.NotPendingOwner.selector);
        t.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert(ProvableVault.NotPendingOwner.selector);
        t.acceptOwnership();

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, alice);
        vm.prank(alice);
        t.acceptOwnership();
        assertEq(t.owner(), alice);
        assertEq(t.pendingOwner(), address(0));

        // old owner lost rights
        vm.startPrank(owner);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.setCap(address(usdc), 1, 1);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.transferOwnership(owner);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.unpause();
        vm.stopPrank();

        // new owner has rights
        vm.prank(alice);
        t.setCap(address(usdc), 1, 1);

        // pending cleared: nobody can accept again
        vm.prank(alice);
        vm.expectRevert(ProvableVault.NotPendingOwner.selector);
        t.acceptOwnership();
    }

    function test_OwnerDoesNotChangeUntilAccepted() public {
        vm.prank(owner);
        t.transferOwnership(alice);
        // the old owner keeps full rights while the transfer is pending
        vm.prank(owner);
        t.setCap(address(usdc), 1, 1);
        vm.prank(alice);
        vm.expectRevert(ProvableVault.NotOwner.selector);
        t.setCap(address(usdc), 2, 2);
    }

    function test_NewOwnerCanUnpauseAndSweep() public {
        vm.prank(operator);
        t.pause();
        vm.prank(owner);
        t.transferOwnership(alice);
        vm.prank(alice);
        t.acceptOwnership();
        vm.startPrank(alice);
        t.unpause();
        t.sweep(address(usdc), alice, 1);
        vm.stopPrank();
        assertFalse(t.paused());
        assertEq(usdc.balanceOf(alice), 1);
    }

    function test_AcceptWithNoPendingReverts() public {
        vm.prank(outsider);
        vm.expectRevert(ProvableVault.NotPendingOwner.selector);
        t.acceptOwnership();
    }

    function test_TransferOwnershipZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(ProvableVault.ZeroAddress.selector);
        t.transferOwnership(address(0));
    }

    function test_TransferOwnershipCanBeOverwrittenBeforeAccept() public {
        vm.startPrank(owner);
        t.transferOwnership(alice);
        t.transferOwnership(bob);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(ProvableVault.NotPendingOwner.selector);
        t.acceptOwnership();
        vm.prank(bob);
        t.acceptOwnership();
        assertEq(t.owner(), bob);
    }

    // ---------------------------------------------------------------- reentrancy
    function _reentrantSetup() internal returns (ReentrantToken rt) {
        rt = new ReentrantToken();
        rt.mint(address(t), 1_000e6);
        vm.startPrank(owner);
        t.setOperator(address(rt));
        t.setCap(address(rt), 100e6, 100e6);
        vm.stopPrank();
        rt.arm(t);
    }

    function test_ReentrantPayoutSeesSpendAlreadyBooked() public {
        ReentrantToken rt = _reentrantSetup();
        // pay the full daily cap; the token calls payout again from inside transfer
        rt.callVault(abi.encodeCall(ProvableVault.payout, (address(rt), alice, 100e6, REF)));
        assertFalse(rt.reenterOk());
        assertEq(rt.reenterRevert(), abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        assertEq(rt.balanceOf(alice), 100e6);
        assertEq(t.remainingToday(address(rt)), 0);
    }

    function test_ReentrantBatchSeesSpendAlreadyBooked() public {
        ReentrantToken rt = _reentrantSetup();
        address[] memory to = new address[](2);
        uint256[] memory amts = new uint256[](2);
        bytes32[] memory refs = new bytes32[](2);
        to[0] = alice;
        to[1] = bob;
        amts[0] = 60e6;
        amts[1] = 40e6;
        rt.callVault(abi.encodeCall(ProvableVault.payoutBatch, (address(rt), to, amts, refs)));
        assertFalse(rt.reenterOk());
        assertEq(rt.reenterRevert(), abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0)));
        assertEq(rt.balanceOf(alice) + rt.balanceOf(bob), 100e6);
    }

    function test_ReentrantPayoutWithHeadroomStaysWithinCap() public {
        ReentrantToken rt = _reentrantSetup();
        // 60 of 100 booked first, so the nested 1 fits, but the total can never pass the cap
        rt.callVault(abi.encodeCall(ProvableVault.payout, (address(rt), alice, 60e6, REF)));
        assertTrue(rt.reenterOk());
        assertEq(t.remainingToday(address(rt)), 100e6 - 60e6 - 1);
        assertEq(rt.balanceOf(alice), 60e6 + 1);
    }

    function test_ReentrantMessengerSeesBurnAlreadyBooked() public {
        vm.prank(owner);
        t.setOperator(address(msgr));
        msgr.arm(t, address(usdc));
        // the messenger is the operator here, so its callback passes the role check
        vm.prank(address(msgr));
        t.payoutCrossChain(address(usdc), bytes32(uint256(1)), 1, PER_TX, 0, 1000, REF);
        // the nested 1 unit fits, and the total is the burn plus the nested payout
        assertTrue(msgr.reenterOk());
        assertEq(t.remainingToday(address(usdc)), PER_DAY - PER_TX - 1);
    }

    function test_ReentrantMessengerAtFullCapIsBlocked() public {
        vm.startPrank(owner);
        t.setOperator(address(msgr));
        t.setCap(address(usdc), 100e6, 100e6);
        vm.stopPrank();
        msgr.arm(t, address(usdc));
        vm.prank(address(msgr));
        t.payoutCrossChain(address(usdc), bytes32(uint256(1)), 1, 100e6, 0, 1000, REF);
        assertFalse(msgr.reenterOk());
        assertEq(
            msgr.reenterRevert(), abi.encodeWithSelector(ProvableVault.CapExceeded.selector, uint256(1), uint256(0))
        );
        assertEq(usdc.balanceOf(address(msgr)), 0);
    }

    // ---------------------------------------------------------------- fuzz: caps
    function testFuzz_PayoutSucceedsIffWithinCaps(uint128 perTx, uint128 perDay, uint256 amount) public {
        amount = bound(amount, 0, 1_000_000e6);
        usdc.mint(address(t), 1_000_000e6);
        vm.prank(owner);
        t.setCap(address(usdc), perTx, perDay);
        vm.prank(operator);
        try t.payout(address(usdc), alice, amount, REF) {
            assertTrue(amount > 0 && amount <= perTx && amount <= perDay);
            assertEq(usdc.balanceOf(alice), amount);
            assertEq(t.remainingToday(address(usdc)), uint256(perDay) - amount);
        } catch {
            assertTrue(amount == 0 || amount > perTx || amount > perDay);
            assertEq(usdc.balanceOf(alice), 0);
            assertEq(t.remainingToday(address(usdc)), perDay);
        }
    }

    function testFuzz_DailyTotalNeverExceedsPerDay(uint128 perTx, uint128 perDay, uint256[8] memory amts, uint8 jump)
        public
    {
        perTx = uint128(bound(perTx, 1, 1_000e6));
        perDay = uint128(bound(perDay, 1, 5_000e6));
        usdc.mint(address(t), 100_000e6);
        vm.prank(owner);
        t.setCap(address(usdc), perTx, perDay);
        uint256 day = block.timestamp / 1 days;
        uint256 paidToday;
        for (uint256 i; i < amts.length; ++i) {
            if (jump % 3 == i % 3 && i != 0) {
                vm.warp(block.timestamp + 1 days);
                day = block.timestamp / 1 days;
                paidToday = 0;
            }
            uint256 a = bound(amts[i], 1, 2_000e6);
            vm.prank(operator);
            try t.payout(address(usdc), alice, a, REF) {
                paidToday += a;
            } catch {}
            assertTrue(paidToday <= perDay);
            assertEq(t.remainingToday(address(usdc)), uint256(perDay) - paidToday);
            assertEq(block.timestamp / 1 days, day);
        }
    }

    function testFuzz_BatchTotalCheckedAsOne(uint128 perTx, uint128 perDay, uint64 a, uint64 b, uint64 c) public {
        perTx = uint128(bound(perTx, 1, type(uint64).max));
        perDay = uint128(bound(perDay, 1, type(uint64).max));
        usdc.mint(address(t), 3 * uint256(type(uint64).max));
        vm.prank(owner);
        t.setCap(address(usdc), perTx, perDay);
        (address[] memory to, uint256[] memory amts, bytes32[] memory refs) = _batch(a, b, c);
        uint256 total = uint256(a) + b + c;
        vm.prank(operator);
        try t.payoutBatch(address(usdc), to, amts, refs) {
            assertTrue(total > 0 && total <= perTx && total <= perDay);
            assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), total);
        } catch {
            assertTrue(total == 0 || total > perTx || total > perDay);
            assertEq(usdc.balanceOf(alice) + usdc.balanceOf(bob), 0);
        }
    }

    function testFuzz_RolloverAlwaysRestoresFullCap(uint64 startTs, uint32 gap) public {
        startTs = uint64(bound(startTs, 1 days, 100_000 days));
        gap = uint32(bound(gap, 1 days, 5_000 days));
        vm.warp(startTs);
        vm.prank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
        vm.warp(uint256(startTs) + gap);
        assertEq(t.remainingToday(address(usdc)), PER_DAY);
        vm.prank(operator);
        t.payout(address(usdc), alice, PER_TX, REF);
    }

    function testFuzz_OnlyOperatorPays(address caller, uint256 amount) public {
        vm.assume(caller != operator);
        amount = bound(amount, 1, PER_TX);
        vm.prank(caller);
        vm.expectRevert(ProvableVault.NotOperator.selector);
        t.payout(address(usdc), alice, amount, REF);
    }

    // ---------------------------------------------------------------- fuzz: Merkle
    function testFuzz_EveryLeafVerifies(uint256 seed, uint8 n_) public {
        uint256 n = bound(n_, 1, 40);
        bytes32[] memory leaves = _leaves(seed, n);
        bytes32[][] memory lv = _levels(leaves);
        vm.prank(operator);
        t.commitBatch(5, lv[lv.length - 1][0], n);
        for (uint256 i; i < n; ++i) {
            assertTrue(t.verifyLeaf(5, leaves[i], _proof(lv, i)));
        }
    }

    function testFuzz_ForeignLeafNeverVerifies(uint256 seed, uint8 n_, bytes32 foreign) public {
        uint256 n = bound(n_, 1, 40);
        bytes32[] memory leaves = _leaves(seed, n);
        for (uint256 i; i < n; ++i) {
            vm.assume(foreign != leaves[i]);
        }
        bytes32[][] memory lv = _levels(leaves);
        vm.prank(operator);
        t.commitBatch(5, lv[lv.length - 1][0], n);
        // the foreign leaf fails against every real proof, and against the empty proof
        for (uint256 i; i < n; ++i) {
            assertFalse(t.verifyLeaf(5, foreign, _proof(lv, i)));
        }
        if (n > 1) assertFalse(t.verifyLeaf(5, foreign, new bytes32[](0)));
    }

    function testFuzz_TamperedProofNeverVerifies(uint256 seed, uint8 n_, uint8 idx_, uint8 pos_, uint256 flip) public {
        uint256 n = bound(n_, 2, 40);
        uint256 idx = bound(idx_, 0, n - 1);
        flip = bound(flip, 1, type(uint256).max);
        bytes32[] memory leaves = _leaves(seed, n);
        bytes32[][] memory lv = _levels(leaves);
        vm.prank(operator);
        t.commitBatch(5, lv[lv.length - 1][0], n);
        bytes32[] memory proof = _proof(lv, idx);
        assertTrue(proof.length > 0);
        uint256 pos = bound(pos_, 0, proof.length - 1);
        proof[pos] = bytes32(uint256(proof[pos]) ^ flip);
        assertFalse(t.verifyLeaf(5, leaves[idx], proof));
    }

    function testFuzz_ProofIsBoundToItsEpoch(uint256 seed, uint8 n_, uint256 otherEpoch) public {
        uint256 n = bound(n_, 1, 40);
        vm.assume(otherEpoch != 5);
        bytes32[] memory leaves = _leaves(seed, n);
        bytes32[][] memory lv = _levels(leaves);
        vm.prank(operator);
        t.commitBatch(5, lv[lv.length - 1][0], n);
        assertTrue(t.verifyLeaf(5, leaves[0], _proof(lv, 0)));
        assertFalse(t.verifyLeaf(otherEpoch, leaves[0], _proof(lv, 0)));
    }

    function testFuzz_CommitIsWriteOnce(uint256 epoch, bytes32 first, bytes32 second) public {
        vm.assume(first != bytes32(0) && second != bytes32(0));
        vm.startPrank(operator);
        t.commitBatch(epoch, first, 1);
        vm.expectRevert(abi.encodeWithSelector(ProvableVault.RootAlreadyCommitted.selector, epoch));
        t.commitBatch(epoch, second, 1);
        vm.stopPrank();
        assertEq(t.batchRoots(epoch), first);
    }
}
