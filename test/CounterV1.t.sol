// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CounterV1, UUPSBase} from "../src/CounterV1.sol";
import {CounterV2} from "../src/CounterV2.sol";

interface Vm {
    function assume(bool condition) external;
    function prank(address sender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function load(address target, bytes32 slot) external view returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function deal(address target, uint256 balance) external;
}

/// @dev Local test fixture only. Initialization must accompany construction in real usage.
contract ERC1967Proxy {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation, bytes memory data) payable {
        assembly {
            sstore(IMPLEMENTATION_SLOT, implementation)
        }
        if (data.length != 0) {
            (bool success, bytes memory result) = implementation.delegatecall(data);
            if (!success) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }

    fallback() external payable {
        assembly {
            let implementation := sload(IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

contract WrongUUIDImplementation {
    function proxiableUUID() external pure returns (bytes32) {
        return keccak256("incompatible.storage.slot");
    }
}

contract RevertingUUIDImplementation {
    error UUIDUnavailable();

    function proxiableUUID() external pure returns (bytes32) {
        revert UUIDUnavailable();
    }
}

contract MissingUUIDImplementation {
    function unrelated() external pure returns (uint256) {
        return 1;
    }
}

/// @dev Allows delegation without making the implementation slot select the call target.
contract DelegateContextProbe {
    function forward(address target, bytes calldata data) external {
        (bool success, bytes memory result) = target.delegatecall(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }
}

abstract contract CounterTestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant STRANGER = address(0xBEEF);

    CounterV1 internal implementationV1;
    CounterV2 internal implementationV2;
    ERC1967Proxy internal proxy;
    CounterV1 internal counter;

    event Incremented(uint256 newCount);
    event Upgraded(address indexed implementation);
    event Initialized(uint64 version);

    function setUp() public virtual {
        implementationV1 = new CounterV1();
        implementationV2 = new CounterV2();
        proxy = new ERC1967Proxy(address(implementationV1), abi.encodeCall(CounterV1.initialize, (address(this))));
        counter = CounterV1(address(proxy));
    }

    function _namespace(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(name))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _erc1967Slot(string memory name) internal pure returns (bytes32) {
        return bytes32(uint256(keccak256(bytes(name))) - 1);
    }

    function _counterSlot() internal pure returns (bytes32) {
        return _namespace("slam100.storage.Counter");
    }

    function _stepSlot() internal pure returns (bytes32) {
        return bytes32(uint256(_counterSlot()) + 1);
    }

    function _implementationSlot() internal pure returns (bytes32) {
        return _erc1967Slot("eip1967.proxy.implementation");
    }

    function _assertBase(address target, address expectedOwner, uint64 initialized) internal view {
        require(UUPSBase(target).owner() == expectedOwner, "owner changed");
        // Owner, version and the cleared initializing flag occupy one packed word.
        bytes32 expected = bytes32(uint256(uint160(expectedOwner)) | (uint256(initialized) << 160));
        require(vm.load(target, _namespace("slam100.storage.Base")) == expected, "base storage changed");
    }

    function _assertImplementation(address expected) internal view {
        require(vm.load(address(proxy), _implementationSlot()) == bytes32(uint256(uint160(expected))), "wrong impl");
    }

    function _assertV1Unchanged(uint256 expectedCount) internal view {
        _assertImplementation(address(implementationV1));
        _assertBase(address(proxy), address(this), 1);
        require(counter.version() == 1, "V1 no longer active");
        require(counter.count() == expectedCount, "count changed");
        require(vm.load(address(proxy), _counterSlot()) == bytes32(expectedCount), "count slot changed");
        require(vm.load(address(proxy), _stepSlot()) == bytes32(0), "step changed");
    }

    function _upgrade(uint256 step) internal returns (CounterV2 upgraded) {
        counter.upgradeToAndCall(address(implementationV2), abi.encodeCall(CounterV2.initializeV2, (step)));
        upgraded = CounterV2(address(proxy));
    }

    function _expectInvalidImplementation(address candidate) internal {
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.ERC1967InvalidImplementation.selector, candidate));
        counter.upgradeToAndCall(candidate, "");
        _assertV1Unchanged(1);
    }
}

contract CounterV1Test is CounterTestBase {
    function testConstructorInitializesProxyAndLocksBothImplementations() public view {
        _assertV1Unchanged(0);
        _assertBase(address(implementationV1), address(0), type(uint64).max);
        _assertBase(address(implementationV2), address(0), type(uint64).max);
        require(implementationV1.count() == 0, "implementation count initialized");
        require(implementationV2.count() == 0 && implementationV2.step() == 0, "V2 implementation state changed");
    }

    function testIncrementIsPublicAndEmitsNewCountFromProxy() public {
        vm.expectEmit(false, false, false, true, address(proxy));
        emit Incremented(1);
        vm.prank(STRANGER);
        counter.increment();
        vm.expectEmit(false, false, false, true, address(proxy));
        emit Incremented(2);
        counter.increment();
        _assertV1Unchanged(2);
        require(implementationV1.count() == 0, "delegatecall mutated implementation");
    }

    function testFuzzIncrementAtStorageBoundary(uint256 start) public {
        vm.assume(start < type(uint256).max);
        vm.store(address(proxy), _counterSlot(), bytes32(start));
        counter.increment();
        _assertV1Unchanged(start + 1);
    }

    function testIncrementOverflowRevertsWithoutChangingStorage() public {
        vm.store(address(proxy), _counterSlot(), bytes32(type(uint256).max));
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        counter.increment();
        _assertV1Unchanged(type(uint256).max);
    }

    function testZeroOwnerRevertsDuringProxyConstruction() public {
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(implementationV1), abi.encodeCall(CounterV1.initialize, (address(0))));
    }

    function testRejectedInitializationDoesNotConsumeVersion() public {
        CounterV1 fresh = CounterV1(address(new ERC1967Proxy(address(implementationV1), "")));
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableInvalidOwner.selector, address(0)));
        fresh.initialize(address(0));
        _assertBase(address(fresh), address(0), 0);
        fresh.initialize(address(this));
        _assertBase(address(fresh), address(this), 1);
    }

    function testImplementationCannotBeInitializedByAnyCaller() public {
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        implementationV1.initialize(address(this));
        vm.prank(STRANGER);
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        implementationV1.initialize(STRANGER);
        _assertBase(address(implementationV1), address(0), type(uint64).max);
    }

    function testProxyInitializationCannotBeRepeatedOrFrontRunAfterConstruction() public {
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        counter.initialize(address(this));
        vm.prank(STRANGER);
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        counter.initialize(STRANGER);
        _assertV1Unchanged(0);
    }

    /// @dev Deployment hazard, not an authentication guarantee: initialize has no predetermined
    /// owner. Omitting constructor data lets the first caller claim a V1 proxy. The supported
    /// deployment above initializes atomically and the preceding test checks that protection.
    function testDocumentsFirstCallerRiskForProxyDeployedWithoutInitializationData() public {
        CounterV1 fresh = CounterV1(address(new ERC1967Proxy(address(implementationV1), "")));
        _assertBase(address(fresh), address(0), 0);
        vm.prank(STRANGER);
        fresh.initialize(STRANGER);
        _assertBase(address(fresh), STRANGER, 1);
        vm.expectRevert(UUPSBase.InvalidInitialization.selector);
        fresh.initialize(address(this));
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableUnauthorizedAccount.selector, address(this)));
        fresh.upgradeToAndCall(address(implementationV2), "");
    }

    function testFuzzNonOwnerCannotUpgrade(address caller) public {
        vm.assume(caller != address(this));
        counter.increment();
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(UUPSBase.OwnableUnauthorizedAccount.selector, caller));
        counter.upgradeToAndCall(address(implementationV2), abi.encodeCall(CounterV2.initializeV2, (7)));
        _assertV1Unchanged(1);
    }

    function testProxiableUUIDIsAvailableOnlyOnImplementations() public {
        require(implementationV1.proxiableUUID() == _implementationSlot(), "wrong V1 UUID");
        require(implementationV2.proxiableUUID() == _implementationSlot(), "wrong V2 UUID");
        vm.expectRevert(UUPSBase.UUPSUnauthorizedCallContext.selector);
        counter.proxiableUUID();
    }

    function testDirectUpgradeCallsRejectImplementationContextBeforeAuthorization() public {
        vm.expectRevert(UUPSBase.UUPSUnauthorizedCallContext.selector);
        implementationV1.upgradeToAndCall(address(implementationV2), "");
        vm.expectRevert(UUPSBase.UUPSUnauthorizedCallContext.selector);
        implementationV2.upgradeToAndCall(address(implementationV1), "");
    }

    function testOnlyProxyRejectsDelegatecallWithMissingOrMismatchedImplementationSlot() public {
        DelegateContextProbe probe = new DelegateContextProbe();
        address[2] memory targets = [address(implementationV1), address(implementationV2)];
        for (uint256 i; i < targets.length; ++i) {
            bytes memory data = abi.encodeCall(UUPSBase.upgradeToAndCall, (targets[1 - i], bytes("")));
            vm.store(address(probe), _implementationSlot(), bytes32(0));
            vm.expectRevert(UUPSBase.UUPSUnauthorizedCallContext.selector);
            probe.forward(targets[i], data);
            vm.store(address(probe), _implementationSlot(), bytes32(uint256(uint160(targets[1 - i]))));
            vm.expectRevert(UUPSBase.UUPSUnauthorizedCallContext.selector);
            probe.forward(targets[i], data);
        }
    }

    function testWrongUUIDRevertsWithReturnedSlotAndPreservesState() public {
        WrongUUIDImplementation wrong = new WrongUUIDImplementation();
        counter.increment();
        vm.expectRevert(
            abi.encodeWithSelector(
                UUPSBase.UUPSUnsupportedProxiableUUID.selector, keccak256("incompatible.storage.slot")
            )
        );
        counter.upgradeToAndCall(address(wrong), "");
        _assertV1Unchanged(1);
    }

    function testNoCodeAndZeroAddressCannotBecomeImplementation() public {
        counter.increment();
        require(STRANGER.code.length == 0, "EOA fixture has code");
        _expectInvalidImplementation(STRANGER);
        _expectInvalidImplementation(address(0));
    }

    function testRevertingOrMissingUUIDCannotBecomeImplementation() public {
        address reverting = address(new RevertingUUIDImplementation());
        address missing = address(new MissingUUIDImplementation());
        counter.increment();
        _expectInvalidImplementation(reverting);
        _expectInvalidImplementation(missing);
    }

    function testProxyCannotBeInstalledAsImplementation() public {
        ERC1967Proxy other =
            new ERC1967Proxy(address(implementationV1), abi.encodeCall(CounterV1.initialize, (address(this))));
        counter.increment();
        _expectInvalidImplementation(address(proxy));
        _expectInvalidImplementation(address(other));
    }

    function testNamespacedConstantsMatchFormulaAndDoNotCollideWithERC1967Slots() public view {
        bytes32 base = _namespace("slam100.storage.Base");
        bytes32 state = _counterSlot();
        require(implementationV1.BASE_STORAGE_LOCATION() == base, "V1 base namespace mismatch");
        require(implementationV2.BASE_STORAGE_LOCATION() == base, "V2 base namespace mismatch");
        require(implementationV1.COUNTER_STORAGE_LOCATION() == state, "V1 counter namespace mismatch");
        require(implementationV2.COUNTER_STORAGE_LOCATION() == state, "V2 counter namespace mismatch");
        require(base != state, "namespace collision");
        require(uint256(base) & 0xff == 0 && uint256(state) & 0xff == 0, "namespace not aligned");
        bytes32[3] memory reserved =
            [_implementationSlot(), _erc1967Slot("eip1967.proxy.admin"), _erc1967Slot("eip1967.proxy.beacon")];
        for (uint256 i; i < reserved.length; ++i) {
            bytes32 page = reserved[i] & ~bytes32(uint256(0xff));
            require(page != base && page != state, "ERC1967 namespace collision");
            if (i != 0) require(vm.load(address(proxy), reserved[i]) == bytes32(0), "reserved slot written");
        }
        _assertV1Unchanged(0);
    }
}
