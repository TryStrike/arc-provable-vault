// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev The slice of ERC20 the vault uses.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @dev Circle CCTP V2 TokenMessenger (Arc Testnet: 0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA, domain 26).
interface ITokenMessengerV2 {
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold
    ) external;
}

/**
 * @title ProvableVault
 * @notice A stablecoin vault that pays users out of a pooled balance, with every payout capped
 * and every result provable. Built for games, prediction markets, payroll and rewards.
 *
 * Deposits are plain token transfers to this address. There is no deposit function and no
 * approval step. Your backend credits them from the token `Transfer` log.
 *
 * Two keys:
 * - The owner (a cold key or multisig) sets the operator and the caps, sweeps funds and unpauses.
 * - The operator (a hot key on your backend) can only pay out, under a per-transaction cap and
 *   a per-day cap for each token, and commit result roots.
 *
 * A leaked operator key can move at most one day's cap. Either key can pause. Only the owner resumes.
 * A token with no cap set cannot be paid out at all.
 *
 * Every payout carries a `ref` (a withdrawal id, bet id or invoice id) so your ledger reconciles
 * against the chain from events alone.
 */
contract ProvableVault {
    error NotOwner();
    error NotOperator();
    error NotPendingOwner();
    error IsPaused();
    error ZeroAddress();
    error ZeroAmount();
    error LengthMismatch();
    error CapExceeded(uint256 requested, uint256 remaining);
    error TransferFailed();
    error ZeroRoot();
    error RootAlreadyCommitted(uint256 epoch);

    /// @param perTx Largest single payout (or batch total) in token units.
    /// @param perDay Largest total paid per UTC day in token units.
    struct Cap {
        uint128 perTx;
        uint128 perDay;
    }

    struct Spent {
        uint64 day;
        uint192 amount;
    }

    address public owner;
    address public operator;
    address public pendingOwner;
    bool public paused;

    /// @notice Circle CCTP V2 TokenMessenger used by `payoutCrossChain`.
    ITokenMessengerV2 public immutable tokenMessenger;

    mapping(address token => Cap) public caps;
    mapping(address token => Spent) public spent;
    /// @notice Merkle root of the results settled in each epoch, committed by the operator.
    mapping(uint256 epoch => bytes32) public batchRoots;

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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        if (paused) revert IsPaused();
        _;
    }

    /// @param tokenMessenger_ CCTP V2 TokenMessenger on this chain.
    /// @param owner_ The admin. It is passed in, never taken from the deployer, so a shared deploy wallet never owns the vault.
    /// @param operator_ The hot key that pays out and commits results.
    constructor(address tokenMessenger_, address owner_, address operator_) {
        if (tokenMessenger_ == address(0) || owner_ == address(0) || operator_ == address(0)) revert ZeroAddress();
        owner = owner_;
        operator = operator_;
        tokenMessenger = ITokenMessengerV2(tokenMessenger_);
        emit OwnershipTransferred(address(0), owner_);
        emit OperatorSet(operator_);
    }

    // ---------------------------------------------------------------------
    // Operator: payouts
    // ---------------------------------------------------------------------

    /// @notice Pay one recipient. A fee is simply not sent: it stays in the vault.
    /// @param ref Your id for this payout. It is emitted so you can reconcile from events.
    function payout(address token, address to, uint256 amount, bytes32 ref) external onlyOperator {
        _spend(token, amount);
        _send(token, to, amount);
        emit Payout(token, to, amount, ref);
    }

    /// @notice Pay several recipients in one transaction. Checked against the caps as one total.
    function payoutBatch(address token, address[] calldata to, uint256[] calldata amounts, bytes32[] calldata refs)
        external
        onlyOperator
    {
        uint256 n = to.length;
        if (n == 0 || amounts.length != n || refs.length != n) revert LengthMismatch();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            total += amounts[i];
        }
        _spend(token, total);
        for (uint256 i; i < n; ++i) {
            _send(token, to[i], amounts[i]);
            emit Payout(token, to[i], amounts[i], refs[i]);
        }
    }

    /// @notice Pay a recipient on another chain through CCTP V2. The token must be one CCTP can burn (USDC).
    /// @param mintRecipient The recipient on the destination chain, left-padded to 32 bytes.
    /// @param domain The CCTP domain of the destination chain.
    /// @param minFinalityThreshold 2000 for standard (finalized), 1000 for fast transfer.
    function payoutCrossChain(
        address token,
        bytes32 mintRecipient,
        uint32 domain,
        uint256 amount,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes32 ref
    ) external onlyOperator {
        if (mintRecipient == bytes32(0)) revert ZeroAddress();
        _spend(token, amount);
        // Exact approval per payout: the messenger can never pull more than this one burn.
        _call(token, abi.encodeCall(IERC20.approve, (address(tokenMessenger), amount)));
        tokenMessenger.depositForBurn(amount, domain, mintRecipient, token, bytes32(0), maxFee, minFinalityThreshold);
        emit CrossChainPayout(token, mintRecipient, domain, amount, maxFee, ref);
    }

    // ---------------------------------------------------------------------
    // Operator: provable results
    // ---------------------------------------------------------------------

    /// @notice Commit the Merkle root of one epoch of results. Write-once: a root can never be changed.
    /// @param epoch Any id you choose: a day, a round range, a pay run.
    /// @param root Root of a sorted-pair Merkle tree over your leaves.
    /// @param count How many leaves the tree has. For readers only, it is not checked.
    function commitBatch(uint256 epoch, bytes32 root, uint256 count) external onlyOperator {
        if (root == bytes32(0)) revert ZeroRoot();
        if (batchRoots[epoch] != bytes32(0)) revert RootAlreadyCommitted(epoch);
        batchRoots[epoch] = root;
        emit BatchCommitted(epoch, root, count);
    }

    /// @notice True when `leaf` is in the committed root of `epoch` (sorted-pair Merkle tree).
    /// Returns false for an epoch with no committed root.
    function verifyLeaf(uint256 epoch, bytes32 leaf, bytes32[] calldata proof) external view returns (bool) {
        bytes32 root = batchRoots[epoch];
        if (root == bytes32(0)) return false;
        bytes32 node = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 sibling = proof[i];
            node = node < sibling
                ? keccak256(abi.encodePacked(node, sibling))
                : keccak256(abi.encodePacked(sibling, node));
        }
        return node == root;
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice What the operator can still pay in `token` today.
    function remainingToday(address token) external view returns (uint256) {
        Spent memory s = spent[token];
        uint256 used = s.day == block.timestamp / 1 days ? s.amount : 0;
        uint256 cap = caps[token].perDay;
        return cap > used ? cap - used : 0;
    }

    // ---------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------

    /// @notice Set the payout caps for a token. Zero for either cap stops payouts of that token.
    function setCap(address token, uint128 perTx, uint128 perDay) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        caps[token] = Cap(perTx, perDay);
        emit CapSet(token, perTx, perDay);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorSet(operator_);
    }

    /// @notice Move funds out without caps: fees to a fee wallet, or everything to a new vault.
    function sweep(address token, address to, uint256 amount) external onlyOwner {
        _send(token, to, amount);
        emit Swept(token, to, amount);
    }

    /// @notice Either key can stop operator actions at once.
    function pause() external {
        if (msg.sender != owner && msg.sender != operator) revert NotOperator();
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Only the owner can resume.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @notice Step one of a handover. The new owner must call `acceptOwnership`.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// Checks the per-tx and per-day caps and books the spend. A token with no cap set pays nothing.
    /// Called before any external call, so a reentrant call sees the spend already booked.
    function _spend(address token, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        Cap memory cap = caps[token];
        if (amount > cap.perTx) revert CapExceeded(amount, cap.perTx);
        uint64 today = uint64(block.timestamp / 1 days);
        Spent memory s = spent[token];
        uint256 used = s.day == today ? s.amount : 0;
        uint256 remaining = cap.perDay > used ? cap.perDay - used : 0;
        if (amount > remaining) revert CapExceeded(amount, remaining);
        // used + amount <= perDay, which fits in uint128, so the cast cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        spent[token] = Spent(today, uint192(used + amount));
    }

    /// The token reverts on a short balance, so there is no separate balance check.
    function _send(address token, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        _call(token, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    /// Calls the token and accepts both a `true` return and no return value (USDT style).
    /// A revert inside the token is passed up as it is.
    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok) {
            if (ret.length == 0) revert TransferFailed();
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        if (token.code.length == 0 || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
