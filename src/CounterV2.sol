// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {UUPSBase} from "./CounterV1.sol";

/// @notice Counter upgrade with an owner-configurable increment.
/// @dev Upgrade an initialized V1 proxy, preferably with initializeV2 encoded in upgradeToAndCall.
/// V1 -> V2 -> V1 preserves count, owner, step and the initialized version. V1 ignores step
/// and increments by one. A later V2 upgrade reuses step; initializeV2 cannot run again.
/// A fresh proxy pointing directly to V2 cannot initialize ownership; start with V1.
contract CounterV2 is UUPSBase {
    /// @custom:storage-location erc7201:slam100.storage.Counter
    struct CounterStorage {
        uint256 count;
        uint256 step;
    }

    // Append fields only: the first word must remain compatible with CounterV1.
    /// @custom:storage-location erc7201:slam100.storage.Counter
    bytes32 public constant COUNTER_STORAGE_LOCATION =
        0x8bf49c0a0ba43eded0eea0ecdea5620133b9942a90b3babba62f2a8c430a3100;

    event Incremented(uint256 newCount);

    constructor() {
        _disableInitializers();
    }

    function initializeV2(uint256 step_) external reinitializer(2) onlyOwner {
        _setStep(step_);
    }

    function increment() external {
        CounterStorage storage state = _counterStorage();
        state.count += state.step == 0 ? 1 : state.step;
        emit Incremented(state.count);
    }

    function setStep(uint256 step_) external onlyOwner {
        _setStep(step_);
    }

    function count() external view returns (uint256) {
        return _counterStorage().count;
    }

    /// @notice Stored step; zero means initializeV2 has not set it and increment uses one.
    function step() external view returns (uint256) {
        return _counterStorage().step;
    }

    function version() external pure returns (uint256) {
        return 2;
    }

    function _setStep(uint256 step_) private {
        require(step_ >= 1, "CounterV2: step must be >= 1");
        _counterStorage().step = step_;
    }

    function _counterStorage() private pure returns (CounterStorage storage state) {
        bytes32 slot = COUNTER_STORAGE_LOCATION;
        assembly {
            state.slot := slot
        }
    }
}
