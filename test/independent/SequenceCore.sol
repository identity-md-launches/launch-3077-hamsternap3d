// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISqueekCore} from "src/interfaces/ISqueekCore.sol";

/// @dev Bounded, append-only certification for stateful tests. Work cannot change once certified.
/// The game never reads block units or difficulty, so this model only supplies round/work fields.
contract SequenceCore is ISqueekCore {
    uint64 public frontier;
    bool public unavailable;
    bool public paused;
    mapping(uint64 => bool) public worked;
    mapping(uint64 => uint64) public cumulative;

    error Unavailable();

    function initialize(uint64 startingFrontier) external {
        require(frontier == 0);
        frontier = startingFrontier;
    }

    function setStatus(bool unavailable_, bool paused_) external {
        unavailable = unavailable_;
        paused = paused_;
    }

    function certify(uint64 count, uint256 workBits) external {
        require(count <= 16);
        require(1793735400 + uint256(frontier + count) * 600 <= block.timestamp, "unclosed round");
        for (uint64 i; i < count; i++) {
            uint64 round = frontier + 1;
            worked[round] = workBits & (uint256(1) << i) != 0;
            cumulative[round] = cumulative[frontier] + (worked[round] ? 1 : 0);
            frontier = round;
        }
    }

    function state() external view returns (CoreState memory s) {
        if (unavailable) revert Unavailable();
        s.settledThroughRound = frontier;
        s.cumulativeWork = cumulative[frontier];
        s.paused = paused;
    }

    function configuration() external pure returns (CoreConfiguration memory c) {
        c.genesisTimestamp = 1793735400;
        c.roundDuration = 600;
        c.maxRoundsPerBatch = 16;
    }

    function roundPage(uint64 afterRound, uint64 throughRound, uint256 maxRecords)
        external
        view
        returns (RoundPage memory p)
    {
        if (unavailable) revert Unavailable();
        if (afterRound > throughRound || throughRound > frontier || maxRecords > 16) revert InvalidRoundPageBounds();
        p.start.cumulativeWork = cumulative[afterRound];
        uint256 count;
        uint64 certified = throughRound;
        for (uint64 r = afterRound + 1; r <= throughRound; r++) {
            if (!worked[r]) continue;
            if (count == maxRecords) {
                certified = r - 1;
                break;
            }
            count++;
        }
        p.rounds = new RoundCheckpoint[](count);
        uint256 index;
        for (uint64 r = afterRound + 1; r <= certified; r++) {
            if (worked[r]) {
                p.rounds[index].roundId = r;
                p.rounds[index++].cumulativeWork = cumulative[r];
            }
        }
        p.certifiedThroughRound = certified;
        p.end.cumulativeWork = cumulative[certified];
    }
}
