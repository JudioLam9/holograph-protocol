/*HOLOGRAPH_LICENSE_HEADER*/

/*SOLIDITY_COMPILER_VERSION*/

import "../abstract/Admin.sol";
import "../abstract/EIP712.sol";
import "../abstract/Initializable.sol";
import "../abstract/NonReentrant.sol";
import "../abstract/Owner.sol";

import "../enum/HolographERC20Event.sol";
import "../enum/InterfaceType.sol";

import "../interface/ERC20.sol";
import "../interface/ERC20Burnable.sol";
import "../interface/HolographERC20Interface.sol";
import "../interface/ERC20Metadata.sol";
import "../interface/ERC20Permit.sol";
import "../interface/ERC20Receiver.sol";
import "../interface/ERC20Safer.sol";
import "../interface/ERC165.sol";
import "../interface/Holographable.sol";
import "../interface/HolographedERC20.sol";
import "../interface/HolographInterface.sol";
import "../interface/HolographerInterface.sol";
import "../interface/HolographRegistryInterface.sol";
import "../interface/InitializableInterface.sol";
import "../interface/HolographInterfacesInterface.sol";
import "../interface/Ownable.sol";

/**
 * @title Holograph Bridgeable ERC-20 Token
 * @author Holograph Foundation
 * @notice A smart contract for minting and managing Holograph Bridgeable ERC20 Tokens.
 * @dev The entire logic and functionality of the smart contract is self-contained.
 */
contract HolographERC20 is Admin, Owner, Initializable, NonReentrant, EIP712, HolographERC20Interface {
  /**
   * @dev bytes32(uint256(keccak256('eip1967.Holograph.holograph')) - 1)
   */
  bytes32 constant _holographSlot = precomputeslot("eip1967.Holograph.holograph");
  /**
   * @dev bytes32(uint256(keccak256('eip1967.Holograph.sourceContract')) - 1)
   */
  bytes32 constant _sourceContractSlot = precomputeslot("eip1967.Holograph.sourceContract");

  /**
   * @dev Configuration for events to trigger for source smart contract.
   */
  uint256 private _eventConfig;

  /**
   * @dev Mapping of all the addresse's balances.
   */
  mapping(address => uint256) private _balances;

  /**
   * @dev Mapping of all authorized operators, and capped amounts.
   */
  mapping(address => mapping(address => uint256)) private _allowances;

  /**
   * @dev Total number of token in circulation.
   */
  uint256 private _totalSupply;

  /**
   * @dev Token name.
   */
  string private _name;

  /**
   * @dev Token ticker symbol.
   */
  string private _symbol;

  /**
   * @dev Token number of decimal places.
   */
  uint8 private _decimals;

  /**
   * @dev List of used up nonces. Used in the ERC20Permit interface functionality.
   */
  mapping(address => uint256) private _nonces;

  /**
   * @notice Only allow calls from bridge smart contract.
   */
  modifier onlyBridge() {
    require(msg.sender == _holograph().getBridge(), "ERC20: bridge only call");
    _;
  }

  /**
   * @notice Only allow calls from source smart contract.
   */
  modifier onlySource() {
    address sourceContract;
    assembly {
      sourceContract := sload(_sourceContractSlot)
    }
    require(msg.sender == sourceContract, "ERC20: source only call");
    _;
  }

  /**
   * @dev Constructor is left empty and init is used instead
   */
  constructor() {}

  /**
   * @notice Used internally to initialize the contract instead of through a constructor
   * @dev This function is called by the deployer/factory when creating a contract
   * @param initPayload abi encoded payload to use for contract initilaization
   */
  function init(bytes memory initPayload) external override returns (bytes4) {
    require(!_isInitialized(), "ERC20: already initialized");
    InitializableInterface sourceContract;
    assembly {
      sstore(_reentrantSlot, 0x0000000000000000000000000000000000000000000000000000000000000001)
      sstore(_ownerSlot, caller())
      sourceContract := sload(_sourceContractSlot)
    }
    (
      string memory contractName,
      string memory contractSymbol,
      uint8 contractDecimals,
      uint256 eventConfig,
      string memory domainSeperator,
      string memory domainVersion,
      bool skipInit,
      bytes memory initCode
    ) = abi.decode(initPayload, (string, string, uint8, uint256, string, string, bool, bytes));
    _name = contractName;
    _symbol = contractSymbol;
    _decimals = contractDecimals;
    _eventConfig = eventConfig;
    if (!skipInit) {
      require(sourceContract.init(initCode) == InitializableInterface.init.selector, "ERC20: could not init source");
    }
    _setInitialized();
    _eip712_init(domainSeperator, domainVersion);
    return InitializableInterface.init.selector;
  }

  /**
   * @dev Purposefully left empty, to prevent running out of gas errors when receiving native token payments.
   */
  receive() external payable {}

  /**
   * @notice Fallback to the source contract.
   * @dev Any function call that is not covered here, will automatically be sent over to the source contract.
   */
  fallback() external payable {
    assembly {
      calldatacopy(0, 0, calldatasize())
      mstore(calldatasize(), caller())
      let result := call(gas(), sload(_sourceContractSlot), callvalue(), 0, add(calldatasize(), 0x20), 0, 0)
      returndatacopy(0, 0, returndatasize())
      switch result
      case 0 {
        revert(0, returndatasize())
      }
      default {
        return(0, returndatasize())
      }
    }
  }

  /*
   * @dev all calls to source contract go through this function in order to inject original msg.sender in calldata
   */
  function _sourceCall(bytes memory payload) private returns (bool output) {
    assembly {
      mstore(add(payload, add(mload(payload), 0x20)), caller())
      // offset memory position by 32 bytes to skip the 32 bytes where bytes length is stored
      // add 32 bytes to bytes length to include the appended msg.sender to calldata
      let result := call(
        gas(),
        sload(_sourceContractSlot),
        callvalue(),
        add(payload, 0x20),
        add(mload(payload), 0x20),
        0,
        0
      )
      let pos := mload(0x40)
      // reserve memory space for return data
      mstore(0x40, add(pos, returndatasize()))
      returndatacopy(pos, 0, returndatasize())
      switch result
      case 0 {
        revert(pos, returndatasize())
      }
      output := mload(pos)
    }
  }

  function decimals() public view returns (uint8) {
    return _decimals;
  }

  /**
   * @dev Although EIP-165 is not required for ERC20 contracts, we still decided to implement it.
   *
   * This makes it easier for external smart contracts to easily identify a valid ERC20 token contract.
   */
  function supportsInterface(bytes4 interfaceId) external view returns (bool) {
    HolographInterfacesInterface interfaces = HolographInterfacesInterface(_interfaces());
    ERC165 erc165Contract;
    assembly {
      erc165Contract := sload(_sourceContractSlot)
    }
    if (
      interfaces.supportsInterface(InterfaceType.ERC20, interfaceId) || erc165Contract.supportsInterface(interfaceId) // check global interfaces // check if source supports interface
    ) {
      return true;
    } else {
      return false;
    }
  }

  function allowance(address account, address spender) public view returns (uint256) {
    return _allowances[account][spender];
  }

  function balanceOf(address account) public view returns (uint256) {
    return _balances[account];
  }

  // solhint-disable-next-line func-name-mixedcase
  function DOMAIN_SEPARATOR() public view returns (bytes32) {
    return _domainSeparatorV4();
  }

  function name() public view returns (string memory) {
    return _name;
  }

  function nonces(address account) public view returns (uint256) {
    return _nonces[account];
  }

  function symbol() public view returns (string memory) {
    return _symbol;
  }

  function totalSupply() public view returns (uint256) {
    return _totalSupply;
  }

  function approve(address spender, uint256 amount) public returns (bool) {
    if (_isEventRegistered(HolographERC20Event.beforeApprove)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.beforeApprove.selector, msg.sender, spender, amount))
      );
    }
    _approve(msg.sender, spender, amount);
    if (_isEventRegistered(HolographERC20Event.afterApprove)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.afterApprove.selector, msg.sender, spender, amount)));
    }
    return true;
  }

  function burn(uint256 amount) public {
    if (_isEventRegistered(HolographERC20Event.beforeBurn)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.beforeBurn.selector, msg.sender, amount)));
    }
    _burn(msg.sender, amount);
    if (_isEventRegistered(HolographERC20Event.afterBurn)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.afterBurn.selector, msg.sender, amount)));
    }
  }

  function burnFrom(address account, uint256 amount) public returns (bool) {
    uint256 currentAllowance = _allowances[account][msg.sender];
    require(currentAllowance >= amount, "ERC20: amount exceeds allowance");
    unchecked {
      _allowances[account][msg.sender] = currentAllowance - amount;
    }
    if (_isEventRegistered(HolographERC20Event.beforeBurn)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.beforeBurn.selector, account, amount)));
    }
    _burn(account, amount);
    if (_isEventRegistered(HolographERC20Event.afterBurn)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.afterBurn.selector, account, amount)));
    }
    return true;
  }

  function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
    uint256 currentAllowance = _allowances[msg.sender][spender];
    require(currentAllowance >= subtractedValue, "ERC20: decreased below zero");
    uint256 newAllowance;
    unchecked {
      newAllowance = currentAllowance - subtractedValue;
    }
    if (_isEventRegistered(HolographERC20Event.beforeApprove)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.beforeApprove.selector, msg.sender, spender, newAllowance))
      );
    }
    _approve(msg.sender, spender, newAllowance);
    if (_isEventRegistered(HolographERC20Event.afterApprove)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.afterApprove.selector, msg.sender, spender, newAllowance))
      );
    }
    return true;
  }

  function bridgeIn(uint32 fromChain, bytes calldata payload) external onlyBridge returns (bytes4) {
    (address from, address to, uint256 amount, bytes memory data) = abi.decode(
      payload,
      (address, address, uint256, bytes)
    );
    _mint(to, amount);
    if (_isEventRegistered(HolographERC20Event.bridgeIn)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.bridgeIn.selector, fromChain, from, to, amount, data)),
        "HOLOGRAPH: bridge in failed"
      );
    }
    return Holographable.bridgeIn.selector;
  }

  function bridgeOut(
    uint32 toChain,
    address sender,
    bytes calldata payload
  ) external onlyBridge returns (bytes4 selector, bytes memory data) {
    (address from, address to, uint256 amount) = abi.decode(payload, (address, address, uint256));
    if (sender != from) {
      uint256 currentAllowance = _allowances[from][sender];
      require(currentAllowance >= amount, "ERC20: amount exceeds allowance");
      unchecked {
        _allowances[from][sender] = currentAllowance - amount;
      }
    }
    if (_isEventRegistered(HolographERC20Event.bridgeOut)) {
      /*
       * @dev making a bridgeOut call to source contract
       *      assembly is used so that msg.sender can be injected in the calldata
       */
      bytes memory sourcePayload = abi.encodeWithSelector(
        HolographedERC20.bridgeOut.selector,
        toChain,
        from,
        to,
        amount
      );
      assembly {
        // it is important to add 32 bytes in order to accommodate the first 32 bytes being used for storing length of bytes
        mstore(add(sourcePayload, add(mload(sourcePayload), 0x20)), caller())
        let result := call(
          gas(),
          sload(_sourceContractSlot),
          callvalue(),
          // start reading data from memory position, plus 32 bytes, to skip bytes length indicator
          add(sourcePayload, 0x20),
          // add an additional 32 bytes to bytes length to include the appended caller address
          add(mload(sourcePayload), 0x20),
          0,
          0
        )
        // when reading back data, skip the first 32 bytes which is used to indicate bytes position in calldata
        // also subtract 32 bytes from returndatasize to accomodate the skipped first 32 bytes
        returndatacopy(data, 0x20, sub(returndatasize(), 0x20))
        switch result
        case 0 {
          revert(0, returndatasize())
        }
      }
    }
    _burn(from, amount);
    return (Holographable.bridgeOut.selector, abi.encode(from, to, amount, data));
  }

  /**
   * @dev Allows the bridge to mint tokens (used for hTokens only).
   */
  function holographBridgeMint(address to, uint256 amount) external onlyBridge returns (bytes4) {
    _mint(to, amount);
    return HolographERC20Interface.holographBridgeMint.selector;
  }

  function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
    uint256 currentAllowance = _allowances[msg.sender][spender];
    uint256 newAllowance;
    unchecked {
      newAllowance = currentAllowance + addedValue;
    }
    unchecked {
      require(newAllowance >= currentAllowance, "ERC20: increased above max value");
    }
    if (_isEventRegistered(HolographERC20Event.beforeApprove)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.beforeApprove.selector, msg.sender, spender, newAllowance))
      );
    }
    _approve(msg.sender, spender, newAllowance);
    if (_isEventRegistered(HolographERC20Event.afterApprove)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.afterApprove.selector, msg.sender, spender, newAllowance))
      );
    }
    return true;
  }

  function onERC20Received(
    address account,
    address sender,
    uint256 amount,
    bytes calldata data
  ) public returns (bytes4) {
    require(_isContract(account), "ERC20: operator not contract");
    if (_isEventRegistered(HolographERC20Event.beforeOnERC20Received)) {
      require(
        _sourceCall(
          abi.encodeWithSelector(
            HolographedERC20.beforeOnERC20Received.selector,
            account,
            sender,
            address(this),
            amount,
            data
          )
        )
      );
    }
    try ERC20(account).balanceOf(address(this)) returns (uint256) {
      // do nothing, just want to see if this reverts due to invalid erc-20 contract
    } catch {
      revert("ERC20: failed getting balance");
    }
    if (_isEventRegistered(HolographERC20Event.afterOnERC20Received)) {
      require(
        _sourceCall(
          abi.encodeWithSelector(
            HolographedERC20.afterOnERC20Received.selector,
            account,
            sender,
            address(this),
            amount,
            data
          )
        )
      );
    }
    return ERC20Receiver.onERC20Received.selector;
  }

  function permit(
    address account,
    address spender,
    uint256 amount,
    uint256 deadline,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) public {
    require(block.timestamp <= deadline, "ERC20: expired deadline");
    bytes32 structHash = keccak256(
      abi.encode(
        precomputekeccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
        account,
        spender,
        amount,
        _useNonce(account),
        deadline
      )
    );
    bytes32 hash = _hashTypedDataV4(structHash);
    address signer = _recover(r, s, v, hash);
    require(signer == account, "ERC20: invalid signature");
    if (_isEventRegistered(HolographERC20Event.beforeApprove)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.beforeApprove.selector, account, spender, amount)));
    }
    _approve(account, spender, amount);
    if (_isEventRegistered(HolographERC20Event.afterApprove)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.afterApprove.selector, account, spender, amount)));
    }
  }

  function safeTransfer(address recipient, uint256 amount) public returns (bool) {
    return safeTransfer(recipient, amount, "");
  }

  function safeTransfer(address recipient, uint256 amount, bytes memory data) public returns (bool) {
    if (_isEventRegistered(HolographERC20Event.beforeSafeTransfer)) {
      require(
        _sourceCall(
          abi.encodeWithSelector(HolographedERC20.beforeSafeTransfer.selector, msg.sender, recipient, amount, data)
        )
      );
    }
    _transfer(msg.sender, recipient, amount);
    if (_isEventRegistered(HolographERC20Event.afterSafeTransfer)) {
      require(
        _sourceCall(
          abi.encodeWithSelector(HolographedERC20.afterSafeTransfer.selector, msg.sender, recipient, amount, data)
        )
      );
    }
    return true;
  }

  function safeTransferFrom(address account, address recipient, uint256 amount) public returns (bool) {
    return safeTransferFrom(account, recipient, amount, "");
  }

  function safeTransferFrom(
    address account,
    address recipient,
    uint256 amount,
    bytes memory data
  ) public returns (bool) {
    if (account != msg.sender) {
      /*
       * @dev This is intentionally enabled to remove friction when operator or bridge needs to move tokens
       */
      if (msg.sender != _holograph().getBridge() && msg.sender != _holograph().getOperator()) {
        uint256 currentAllowance = _allowances[account][msg.sender];
        require(currentAllowance >= amount, "ERC20: amount exceeds allowance");
        unchecked {
          _allowances[account][msg.sender] = currentAllowance - amount;
        }
      }
    }
    if (_isEventRegistered(HolographERC20Event.beforeSafeTransfer)) {
      require(
        _sourceCall(
          abi.encodeWithSelector(HolographedERC20.beforeSafeTransfer.selector, account, recipient, amount, data)
        )
      );
    }
    _transfer(account, recipient, amount);
    if (_isEventRegistered(HolographERC20Event.afterSafeTransfer)) {
      require(
        _sourceCall(
          abi.encodeWithSelector(HolographedERC20.afterSafeTransfer.selector, account, recipient, amount, data)
        )
      );
    }
    return true;
  }

  /**
   * @dev Allows for source smart contract to burn tokens.
   */
  function sourceBurn(address from, uint256 amount) external onlySource {
    _burn(from, amount);
  }

  /**
   * @dev Allows for source smart contract to mint tokens.
   */
  function sourceMint(address to, uint256 amount) external onlySource {
    _mint(to, amount);
  }

  /**
   * @dev Allows for source smart contract to mint a batch of token amounts.
   */
  function sourceMintBatch(address[] calldata wallets, uint256[] calldata amounts) external onlySource {
    for (uint256 i = 0; i < wallets.length; i++) {
      _mint(wallets[i], amounts[i]);
    }
  }

  /**
   * @dev Allows for source smart contract to transfer tokens.
   */
  function sourceTransfer(address from, address to, uint256 amount) external onlySource {
    _transfer(from, to, amount);
  }

  /**
   * @dev Allows for source smart contract to withdraw contract balance.
   */
  function sourceWithdraw(address payable destination) external onlySource {
    destination.transfer(address(this).balance);
  }

  function transfer(address recipient, uint256 amount) public returns (bool) {
    if (_isEventRegistered(HolographERC20Event.beforeTransfer)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.beforeTransfer.selector, msg.sender, recipient, amount))
      );
    }
    _transfer(msg.sender, recipient, amount);
    if (_isEventRegistered(HolographERC20Event.afterTransfer)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.afterTransfer.selector, msg.sender, recipient, amount))
      );
    }
    return true;
  }

  function transferFrom(address account, address recipient, uint256 amount) public returns (bool) {
    if (account != msg.sender) {
      /*
       * @dev This is intentionally enabled to remove friction when operator or bridge needs to move tokens
       */
      if (msg.sender != _holograph().getBridge() && msg.sender != _holograph().getOperator()) {
        uint256 currentAllowance = _allowances[account][msg.sender];
        require(currentAllowance >= amount, "ERC20: amount exceeds allowance");
        unchecked {
          _allowances[account][msg.sender] = currentAllowance - amount;
        }
      }
    }
    if (_isEventRegistered(HolographERC20Event.beforeTransfer)) {
      require(
        _sourceCall(abi.encodeWithSelector(HolographedERC20.beforeTransfer.selector, account, recipient, amount))
      );
    }
    _transfer(account, recipient, amount);
    if (_isEventRegistered(HolographERC20Event.afterTransfer)) {
      require(_sourceCall(abi.encodeWithSelector(HolographedERC20.afterTransfer.selector, account, recipient, amount)));
    }
    return true;
  }

  function _approve(address account, address spender, uint256 amount) private {
    require(account != address(0), "ERC20: account is zero address");
    require(spender != address(0), "ERC20: spender is zero address");
    _allowances[account][spender] = amount;
    emit Approval(account, spender, amount);
  }

  function _burn(address account, uint256 amount) private {
    require(account != address(0), "ERC20: account is zero address");
    uint256 accountBalance = _balances[account];
    require(accountBalance >= amount, "ERC20: amount exceeds balance");
    unchecked {
      _balances[account] = accountBalance - amount;
    }
    _totalSupply -= amount;
    _registryTransfer(account, address(0), amount);
  }

  /**
   * @notice Mints tokens.
   * @dev Mint a specific amount of tokens to a specific address.
   * @param to Address to mint to.
   * @param amount Amount of tokens to mint.
   */
  function _mint(address to, uint256 amount) private {
    require(to != address(0), "ERC20: minting to burn address");
    _totalSupply += amount;
    _balances[to] += amount;
    _registryTransfer(address(0), to, amount);
  }

  function _transfer(address account, address recipient, uint256 amount) private {
    require(account != address(0), "ERC20: account is zero address");
    require(recipient != address(0), "ERC20: recipient is zero address");
    uint256 accountBalance = _balances[account];
    require(accountBalance >= amount, "ERC20: amount exceeds balance");
    unchecked {
      _balances[account] = accountBalance - amount;
    }
    _balances[recipient] += amount;
    _registryTransfer(account, recipient, amount);
  }

  function _registryTransfer(address _from, address _to, uint256 _amount) private {
    emit Transfer(_from, _to, _amount);
    HolographRegistryInterface(_holograph().getRegistry()).holographableEvent(
      abi.encode(
        // keccak256("TransferERC20(address,address,uint256)")
        bytes32(precomputekeccak256("TransferERC20(address,address,uint256)")),
        _from,
        _to,
        _amount
      )
    );
  }

  /**
   * @dev "Consume a nonce": return the current value and increment.
   *
   * _Available since v4.1._
   */
  function _useNonce(address account) private returns (uint256 current) {
    current = _nonces[account];
    _nonces[account]++;
  }

  function _isContract(address contractAddress) private view returns (bool) {
    bytes32 codehash;
    assembly {
      codehash := extcodehash(contractAddress)
    }
    return (codehash != 0x0 && codehash != precomputekeccak256(""));
  }

  /**
   * @dev Internal function used for identifying signer
   */
  function _recover(bytes32 r, bytes32 s, uint8 v, bytes32 hash) private pure returns (address signer) {
    if (v < 27) {
      v += 27;
    }
    require(v == 27 || v == 28, "ERC20: invalid v-value");
    // prevent signature malleability by checking if s-value is in the upper range
    if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
      // if s-value is in upper range, calculate a new s-value
      s = bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s));
      // flip the v-value
      if (v == 27) {
        v = 28;
      } else {
        v = 27;
      }
      // check if s-value is still in upper range
      require(
        uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
        "ERC20: invalid s-value"
      );
    }
    signer = ecrecover(hash, v, r, s);
    require(signer != address(0), "ERC20: zero address signer");
  }

  /**
   * @dev Get the interfaces contract address.
   */
  function _interfaces() private view returns (address) {
    return _holograph().getInterfaces();
  }

  function owner() public view override returns (address) {
    Ownable ownableContract;
    assembly {
      ownableContract := sload(_sourceContractSlot)
    }
    return ownableContract.owner();
  }

  function _holograph() private view returns (HolographInterface holograph) {
    assembly {
      holograph := sload(_holographSlot)
    }
  }

  function _isEventRegistered(HolographERC20Event _eventName) private view returns (bool) {
    return ((_eventConfig >> uint256(_eventName)) & uint256(1) == 1 ? true : false);
  }
}
