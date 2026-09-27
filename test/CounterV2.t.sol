// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CounterV1, UUPSBase} from "../src/CounterV1.sol";
import {CounterV2} from "../src/CounterV2.sol";
import {CounterTestBase} from "./CounterV1.t.sol";

contract CounterV2Test is CounterTestBase {
    function _assertV2(CounterV2 upgraded, uint256 expectedCount, uint256 expectedStep, uint64 initialized)
        internal
        view
    {
        _assertImplementation(address(implementationV2));
        _assertBase(address(proxy), address(this), initialized);
        require(upgraded.version() == 2, "V2 not active");
        require(upgraded.count() == expectedCount, "count not preserved");
        require(upgraded.step() == expectedStep, "wrong step");
        require(vm.load(address(proxy), _counterSlot()) == bytes32(expectedCount), "wrong raw count");
        require(vm.load(address(proxy), _stepSlot()) == bytes32(expectedStep), "wrong raw step");
        require(vm.load(address(proxy), _erc1967Slot("eip1967.proxy.admin")) == bytes32(0), "admin slot changed");
        require(vm.load(address(proxy), _erc1967Slot("eip1967.proxy.beacon")) == bytes32(0), "beacon slot changed");
    }

    function testUpgradeAndInitializePreservesCountOwnerAndAppendsStep() public {
        counter.increment();
        counter.increment();
        vm.expectEmit(true, false, false, true, address(proxy));
        emit Upgraded(address(implementationV2));
        vm.expectEmit(false, false, false, true, address(proxy));
        emit Initialized(2);
        CounterV2 upgraded = _upgrade(7);
        _assertV2(upgraded, 2, 7, 2);
        vm.expectEmit(false, false, false, true, address(proxy));
        emit Incremented(9);
        vm.prank(STRANGER);
        upgraded.increment();
        _assertV2(upgraded, 9, 7, 2);
        _assertBase(address(implementationV1), address(0), type(uint64).max);
        _assertBase(address(implementationV2), address(0), type(uint64).max);
        require(implementationV1.count() == 0, "V1 implementation count changed");
        require(implementationV2.count() == 0 && implementationV2.step() == 0, "V2 implementation state changed");
    }

    function testFuzzUpgradePreservesArbitraryCountAndUsesStep(uint128 oldCount, uint128 step) public {
        vm.assume(step != 0);
        vm.store(address(proxy), _counterSlot(), bytes32(uint256(oldCount)));
        CounterV2 upgraded = _upgrade(step);
        _assertV2(upgraded, oldCount, step, 2);
        upgraded.increment();
        _assertV2(upgraded, uint256(oldCount) + step, step, 2);
    }

    function testUpgradeWithoutInitializerDefaultsToOneThenAllowsOwnerInitialization() public {
        counter.increment();
        counter.upgradeToAndCall(address(implementationV2), "");
        CounterV2 upgraded = CounterV2(address(proxy));
        _assertV2(upgraded, 1, 0, 1);
        upgraded.increment();
        _assertV2(upgraded, 2, 0, 1);
        upgraded.initializeV2(3);
        upgraded.increment();
        _assertV2(upgraded, 5, 3, 2);
    }

    function testInitializeV2CannotRunOnImplementation() public {
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        implementationV2.initializeV2(2);
        vm.prank(STRANGER);
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        implementationV2.initializeV2(1);
        _assertBase(address(implementationV2), address(0), type(uint64).max);
        require(implementationV2.step() == 0, "implementation acquired a step");
    }

    function testInitializeV2CannotRunTwiceOnProxy() public {
        CounterV2 upgraded = _upgrade(4);
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        upgraded.initializeV2(9);
        _assertV2(upgraded, 0, 4, 2);
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        upgraded.upgradeToAndCall(address(implementationV2), abi.encodeCall(CounterV2.initializeV2, (10)));
        _assertV2(upgraded, 0, 4, 2);
    }

    function testFuzzNonOwnerCannotFrontRunV2Initialization(address caller) public {
        vm.assume(caller != address(this));
        counter.upgradeToAndCall(address(implementationV2), "");
        CounterV2 upgraded = CounterV2(address(proxy));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableUnauthorizedAccount.selector, caller));
        upgraded.initializeV2(100);
        _assertV2(upgraded, 0, 0, 1);
        // A failed caller must not consume reinitializer(2) and deny the owner its use.
        upgraded.initializeV2(5);
        _assertV2(upgraded, 0, 5, 2);
    }

    function testZeroStepDuringAtomicUpgradeRevertsEntireUpgradeAndCanBeRetried() public {
        counter.increment();
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "CounterV2: step must be >= 1"));
        counter.upgradeToAndCall(address(implementationV2), abi.encodeCall(CounterV2.initializeV2, (0)));
        _assertV1Unchanged(1);
        CounterV2 upgraded = _upgrade(1);
        _assertV2(upgraded, 1, 1, 2);
    }

    function testZeroStepDuringDeferredInitializationDoesNotConsumeVersion() public {
        counter.upgradeToAndCall(address(implementationV2), "");
        CounterV2 upgraded = CounterV2(address(proxy));
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "CounterV2: step must be >= 1"));
        upgraded.initializeV2(0);
        _assertV2(upgraded, 0, 0, 1);
        upgraded.initializeV2(1);
        _assertV2(upgraded, 0, 1, 2);
    }

    function testOwnerCanChangeStepWithoutChangingCountOrInitializationVersion() public {
        CounterV2 upgraded = _upgrade(4);
        upgraded.increment();
        upgraded.setStep(1);
        _assertV2(upgraded, 4, 1, 2);
        upgraded.increment();
        upgraded.setStep(20);
        upgraded.increment();
        _assertV2(upgraded, 25, 20, 2);
    }

    function testSetStepBeforeInitializeV2DoesNotConsumeInitializer() public {
        counter.upgradeToAndCall(address(implementationV2), "");
        CounterV2 upgraded = CounterV2(address(proxy));
        upgraded.setStep(5);
        upgraded.increment();
        _assertV2(upgraded, 5, 5, 1);
        upgraded.initializeV2(2);
        _assertV2(upgraded, 5, 2, 2);
    }

    function testFuzzNonOwnerCannotSetStepOrUpgradeV2(address caller) public {
        vm.assume(caller != address(this));
        CounterV2 upgraded = _upgrade(3);
        upgraded.increment();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableUnauthorizedAccount.selector, caller));
        upgraded.setStep(100);
        _assertV2(upgraded, 3, 3, 2);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableUnauthorizedAccount.selector, caller));
        upgraded.upgradeToAndCall(address(implementationV1), "");
        _assertV2(upgraded, 3, 3, 2);
    }

    function testSetStepRejectsZeroAndPreservesPreviousStep() public {
        CounterV2 upgraded = _upgrade(6);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "CounterV2: step must be >= 1"));
        upgraded.setStep(0);
        _assertV2(upgraded, 0, 6, 2);
    }

    function testMaximumStepIsAcceptedAndOverflowRollsBackCount() public {
        CounterV2 upgraded = _upgrade(type(uint256).max);
        upgraded.increment();
        _assertV2(upgraded, type(uint256).max, type(uint256).max, 2);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        upgraded.increment();
        _assertV2(upgraded, type(uint256).max, type(uint256).max, 2);
    }

    function testSetStepAcceptsMaximumValue() public {
        CounterV2 upgraded = _upgrade(1);
        upgraded.setStep(type(uint256).max);
        upgraded.increment();
        _assertV2(upgraded, type(uint256).max, type(uint256).max, 2);
    }

    function testV2ProxiableUUIDRejectsProxyContext() public {
        CounterV2 upgraded = _upgrade(2);
        vm.expectRevert(UUPSBase.UUPSUnauthorizedCallContext.selector);
        upgraded.proxiableUUID();
    }

    function testValueWithEmptyUpgradeDataRevertsAndRestoresImplementation() public {
        vm.deal(address(this), 1 ether);
        counter.increment();
        vm.expectRevert(UUPSBase.ERC1967NonPayable.selector);
        counter.upgradeToAndCall{value: 1 wei}(address(implementationV2), "");
        _assertV1Unchanged(1);
        require(address(proxy).balance == 0, "reverted upgrade retained value");
        require(address(this).balance == 1 ether, "reverted upgrade spent value");
    }

    /// @dev Downgrades preserve storage but V1 deliberately ignores step. Re-upgrading to V2
    /// reuses that step and the version-2 initialization lock; it must not reinitialize V2.
    function testRoundTripV1V2V1V2PreservesStorageAndInitializationLocks() public {
        counter.increment();
        CounterV2 upgraded = _upgrade(5);
        upgraded.increment();
        upgraded.setStep(7);
        _assertV2(upgraded, 6, 7, 2);
        upgraded.upgradeToAndCall(address(implementationV1), "");
        _assertImplementation(address(implementationV1));
        _assertBase(address(proxy), address(this), 2);
        require(counter.version() == 1 && counter.count() == 6, "downgrade lost count");
        require(vm.load(address(proxy), _stepSlot()) == bytes32(uint256(7)), "downgrade erased step");
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        counter.initialize(STRANGER);
        counter.increment();
        require(counter.count() == 7, "V1 must increment by one after downgrade");
        require(vm.load(address(proxy), _stepSlot()) == bytes32(uint256(7)), "V1 corrupted appended step");
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        counter.upgradeToAndCall(address(implementationV2), abi.encodeCall(CounterV2.initializeV2, (9)));
        _assertImplementation(address(implementationV1));
        _assertBase(address(proxy), address(this), 2);
        require(counter.count() == 7, "failed reinitialization changed count");
        counter.upgradeToAndCall(address(implementationV2), "");
        _assertV2(upgraded, 7, 7, 2);
        upgraded.increment();
        _assertV2(upgraded, 14, 7, 2);
    }

    function testDowngradeCannotReinitializeV1AtomicallyAndRollsBack() public {
        CounterV2 upgraded = _upgrade(3);
        upgraded.increment();
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        upgraded.upgradeToAndCall(address(implementationV1), abi.encodeCall(CounterV1.initialize, (STRANGER)));
        _assertV2(upgraded, 3, 3, 2);
    }
}
