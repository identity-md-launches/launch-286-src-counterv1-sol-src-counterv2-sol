// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal UUPS, ownership and initialization machinery shared by both versions.
abstract contract UUPSBase {
    error InvalidInitialization();
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    error UUPSUnauthorizedCallContext();
    error UUPSUnsupportedProxiableUUID(bytes32 slot);
    error ERC1967InvalidImplementation(address implementation);
    error ERC1967NonPayable();

    event Initialized(uint64 version);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Upgraded(address indexed implementation);

    /// @custom:storage-location erc7201:slam100.storage.Base
    struct BaseStorage {
        address owner;
        uint64 initialized;
        bool initializing;
    }

    // keccak256(abi.encode(uint256(keccak256("slam100.storage.Base")) - 1)) & ~bytes32(uint256(0xff))
    /// @custom:storage-location erc7201:slam100.storage.Base
    bytes32 public constant BASE_STORAGE_LOCATION = 0x2cbd21c322299190e0889117950aa74ecfddd2762549724ffc5742aaefe36900;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private immutable _self = address(this);

    modifier initializer() {
        BaseStorage storage state = _baseStorage();
        if (state.initializing || state.initialized != 0) revert InvalidInitialization();
        state.initialized = 1;
        state.initializing = true;
        _;
        state.initializing = false;
        emit Initialized(1);
    }

    modifier reinitializer(uint64 newVersion) {
        BaseStorage storage state = _baseStorage();
        if (state.initializing || state.initialized >= newVersion) revert InvalidInitialization();
        state.initialized = newVersion;
        state.initializing = true;
        _;
        state.initializing = false;
        emit Initialized(newVersion);
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    modifier onlyProxy() {
        if (address(this) == _self || _implementation() != _self) revert UUPSUnauthorizedCallContext();
        _;
    }

    function owner() public view returns (address) {
        return _baseStorage().owner;
    }

    /// @dev Delegated calls must fail so a proxy cannot be installed as its own implementation.
    function proxiableUUID() external view returns (bytes32) {
        if (address(this) != _self) revert UUPSUnauthorizedCallContext();
        return IMPLEMENTATION_SLOT;
    }

    /// @notice Upgrade this proxy and optionally initialize the new implementation atomically.
    /// @dev UUID compatibility is not a safety audit; the owner must trust the new implementation.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable onlyProxy onlyOwner {
        if (newImplementation.code.length == 0) revert ERC1967InvalidImplementation(newImplementation);
        try UUPSBase(newImplementation).proxiableUUID() returns (bytes32 slot) {
            if (slot != IMPLEMENTATION_SLOT) revert UUPSUnsupportedProxiableUUID(slot);
        } catch {
            revert ERC1967InvalidImplementation(newImplementation);
        }

        assembly {
            sstore(IMPLEMENTATION_SLOT, newImplementation)
        }
        emit Upgraded(newImplementation);

        if (data.length != 0) {
            (bool success, bytes memory result) = newImplementation.delegatecall(data);
            if (!success) {
                assembly {
                    revert(add(result, 0x20), mload(result))
                }
            }
        } else if (msg.value != 0) {
            revert ERC1967NonPayable();
        }
    }

    function _disableInitializers() internal {
        BaseStorage storage state = _baseStorage();
        if (state.initializing) revert InvalidInitialization();
        if (state.initialized != type(uint64).max) {
            state.initialized = type(uint64).max;
            emit Initialized(type(uint64).max);
        }
    }

    function _initializeOwner(address initialOwner) internal {
        if (initialOwner == address(0)) revert OwnableInvalidOwner(address(0));
        _baseStorage().owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    function _baseStorage() private pure returns (BaseStorage storage state) {
        bytes32 slot = BASE_STORAGE_LOCATION;
        assembly {
            state.slot := slot
        }
    }

    function _implementation() private view returns (address implementation) {
        assembly {
            implementation := sload(IMPLEMENTATION_SLOT)
        }
    }
}

/// @notice Counter intended for local ERC-1967 proxy exercises only.
/// @dev Deploy the proxy with initialize data: an uninitialized proxy can be claimed by anyone.
contract CounterV1 is UUPSBase {
    /// @custom:storage-location erc7201:slam100.storage.Counter
    struct CounterStorage {
        uint256 count;
    }

    // keccak256(abi.encode(uint256(keccak256("slam100.storage.Counter")) - 1)) & ~bytes32(uint256(0xff))
    /// @custom:storage-location erc7201:slam100.storage.Counter
    bytes32 public constant COUNTER_STORAGE_LOCATION =
        0x8bf49c0a0ba43eded0eea0ecdea5620133b9942a90b3babba62f2a8c430a3100;

    event Incremented(uint256 newCount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        _initializeOwner(initialOwner);
    }

    function increment() external {
        CounterStorage storage state = _counterStorage();
        state.count += 1;
        emit Incremented(state.count);
    }

    function count() external view returns (uint256) {
        return _counterStorage().count;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function _counterStorage() private pure returns (CounterStorage storage state) {
        bytes32 slot = COUNTER_STORAGE_LOCATION;
        assembly {
            state.slot := slot
        }
    }
}
