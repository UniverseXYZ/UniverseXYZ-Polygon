// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.5;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./ISmartYieldProvider.sol";
import "./matic/IRootChainManager.sol";
import "./matic/IERC20ChildToken.sol";

contract PolygonTokenHarvester is OwnableUpgradeable {
    using SafeERC20 for IERC20;

    bool private _onRootChain;

    address public rootChainManager;
    mapping(address => uint256) public lastWithdraw;
    uint256 public withdrawCooldown;

    event TransferToOwner(address indexed caller, address indexed owner, address indexed token, uint256 amount);
    event WithdrawOnRoot(address indexed caller);
    event WithdrawOnChild(address indexed caller, address indexed token, uint256 amount);

    function initialize(uint256 _withdrawCooldown, address _rootChainManager) initializer public {
        __Ownable_init();

        if (_rootChainManager != address(0)) {
            _onRootChain = true;
            rootChainManager = _rootChainManager;
        } else {
            _onRootChain = false;
        }

        withdrawCooldown = _withdrawCooldown;
     }

    /// @notice Allows the call only on the root chain
    /// @dev Checks is based on rootChainManager being set
    modifier onlyOnRoot {
        require(
            _onRootChain == true,
            "Harvester: should only be called on root chain"
        );
        _;
    }

    /// @notice Allows the call only on the child chain
    /// @dev Checks is based on rootChainManager being not set
    modifier onlyOnChild {
        require(
            _onRootChain == false,
            "Harvester: should only be called on child chain"
        );
        _;
    }

    /// @notice Sets the minimum number of blocks that must pass between withdrawals
    /// @dev This limit is set to not spam the withdrawal process with lots of small withdrawals
    /// @param _withdrawCooldown Number of blocks
    function setWithdrawCooldown(uint256 _withdrawCooldown) public onlyOwner onlyOnChild {
        withdrawCooldown = _withdrawCooldown;
    }

    // Root Chain Related Functions

    /// @notice Withdraws to itself exited funds from Polygon
    /// @dev Forwards the exit call to the Polygon rootChainManager
    /// @param _data Exit payload created with the Matic SDK
    /// @return Bytes return of the rootChainManager exit call
    function withdrawOnRoot(bytes memory _data) public onlyOnRoot returns (bytes memory) {
        (bool success, bytes memory returnData) = rootChainManager.call(_data);
        require(success, string(returnData));

        emit WithdrawOnRoot(_msgSender());

        return returnData;
    }

    /// @notice Transfers full balance of token to owner
    /// @dev Use this after withdrawOnRoot to transfer what you have exited from Polygon to owner
    /// @param _token Address of token to transfer
    function transferToOwner(address _token) public onlyOnRoot {
        require(_token != address(0), "Harvester: token address must be specified");

        IERC20 erc20 = IERC20(_token);

        address to = owner();

        uint256 amount = erc20.balanceOf(address(this));
        erc20.safeTransfer(to, amount);

        emit TransferToOwner(_msgSender(), to, _token, amount);
    }

    function withdrawAndTransferToOwner(bytes memory _data, address _token) public onlyOnRoot returns (bytes memory) {
        bytes memory returnData =  withdrawOnRoot(_data);
        transferToOwner(_token);

        return returnData;
    }

    // Child Chain Related Functions
    function withdrawOnChild(address _childToken) public onlyOnChild {
        require(_childToken != address(0), "Harvester: child token address must be specified");

        // if cooldown has not passed, we just skip it
        if (block.number < lastWithdraw[_childToken] + withdrawCooldown) {
            return;
        }
        lastWithdraw[_childToken] = block.number;

        IERC20ChildToken erc20 = IERC20ChildToken(_childToken);

        uint256 amount = erc20.balanceOf(address(this));
        erc20.withdraw(amount);

        emit WithdrawOnChild(_msgSender(), _childToken, amount);
    }

    function claimAndWithdrawOnChild(address _syProvider) public onlyOnChild {
        require(_syProvider != address(0), "Harvester: sy provider address must not be 0x0");

        ISmartYieldProvider provider = ISmartYieldProvider(_syProvider);
        address underlying = provider.uToken();

        provider.transferFees();
        withdrawOnChild(underlying);
    }
}
