// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "../../src/interfaces/ISqueekCore.sol";

/// @notice A local stand-in for SqueekCore v3 that reproduces the documented read behaviour the
/// hook depends on: `state().settledThroughRound` as the certified frontier, and `roundPage`
/// returning only rounds with work, start exclusive and end inclusive, at most 16 records, reverting
/// with `InvalidRoundPageBounds` on a reversed range, an end past the frontier or more than 16
/// records. It can also be switched to revert on every read (a dead or reverting proxy) or report
/// `paused`.
contract MockSqueekCore is ISqueekCore {
    uint64 public frontier;
    bool public reverting;
    bool public pausedFlag;
    mapping(uint64 round => uint64 work) public workOf;
    bool public customConfiguration;
    uint64 public genesis;
    uint64 public duration;
    bool public stateReverting;
    bool public configurationReverting;
    bool public pageReverting;

    error Reverting();

    function setFrontier(uint64 newFrontier) external {
        frontier = newFrontier;
    }

    function setWork(uint64 round, uint64 work) external {
        workOf[round] = work;
    }

    /// @notice Marks rounds `from` through `through` as having `work` each.
    function setWorkRange(uint64 from, uint64 through, uint64 work) external {
        for (uint64 r = from; r <= through; r++) {
            workOf[r] = work;
        }
    }

    function setReverting(bool value) external {
        reverting = value;
    }

    function setPaused(bool value) external {
        pausedFlag = value;
    }

    function setConfiguration(uint64 genesis_, uint64 duration_) external {
        customConfiguration = true;
        genesis = genesis_;
        duration = duration_;
    }

    function setReadFailures(bool state_, bool configuration_, bool page_) external {
        stateReverting = state_;
        configurationReverting = configuration_;
        pageReverting = page_;
    }

    function state() external view returns (CoreState memory result) {
        if (reverting || stateReverting) revert Reverting();
        uint64 cumulative = _cumulativeThrough(frontier);
        result.settledThroughRound = frontier;
        result.cumulativeWork = cumulative;
        result.cumulativeBlockUnits = uint96(cumulative) * 1e8;
        result.blockHeight = cumulative / 11;
        result.workPerThousandBlocks = 11723;
        result.authorizationNonce = frontier;
        result.paused = pausedFlag;
    }

    function configuration() external view returns (CoreConfiguration memory result) {
        if (reverting || configurationReverting) revert Reverting();
        result.streamId = 0x52e443e4e0d236ff0c07f4cdc518c594a3d680d20abb1481510efbed0ec73633;
        result.genesisTimestamp = customConfiguration ? genesis : 1793735400;
        result.roundDuration = customConfiguration ? duration : 600;
        result.maxWorkPerRound = 10000;
        result.maxRoundsPerBatch = 16;
        result.initialWorkPerThousandBlocks = 10000;
        result.targetBlocksPerActiveRound = 40;
        result.difficultySmoothingRounds = 30;
        result.blockUnitsPerBlock = 1e9;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory result)
    {
        if (reverting || pageReverting) revert Reverting();
        if (afterRound > throughRound || throughRound > frontier || maxRecords > 16) revert InvalidRoundPageBounds();

        uint64 cumulative = _cumulativeThrough(afterRound);
        result.start = LedgerPosition(cumulative, uint96(cumulative) * 1e8, 11723);

        uint256 count;
        for (uint64 r = afterRound + 1; r <= throughRound; r++) {
            if (workOf[r] > 0) count++;
        }
        if (count > maxRecords) count = maxRecords;
        result.rounds = new RoundCheckpoint[](count);

        uint64 certified = throughRound;
        uint256 index;
        for (uint64 r = afterRound + 1; r <= throughRound; r++) {
            uint64 work = workOf[r];
            if (work == 0) continue;
            if (index == count) {
                // The record cap was hit: the page ends at the last record it carries.
                certified = result.rounds[count - 1].roundId;
                break;
            }
            cumulative += work;
            result.rounds[index++] = RoundCheckpoint({
                roundId: r,
                cumulativeWork: cumulative,
                cumulativeBlockUnits: uint96(cumulative) * 1e8,
                workPerThousandBlocks: 11723,
                dataHash: keccak256(abi.encode(r, work))
            });
        }
        result.certifiedThroughRound = certified;
        result.end = LedgerPosition(cumulative, uint96(cumulative) * 1e8, 11723);
    }

    function _cumulativeThrough(uint64 round) private view returns (uint64 cumulative) {
        for (uint64 r = 1; r <= round; r++) {
            cumulative += workOf[r];
        }
    }
}
