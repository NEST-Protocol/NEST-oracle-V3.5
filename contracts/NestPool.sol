// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.6.12;

import "./lib/SafeMath.sol";
import "./lib/AddressPayable.sol";
import "./lib/SafeERC20.sol";
import './lib/TransferHelper.sol';
import "./iface/INestPool.sol";
import "./iface/INestDAO.sol";
import "./iface/INestMining.sol";
import "./iface/INestQuery.sol";
import "./iface/INestStaking.sol";
import "./iface/INNRewardPool.sol";
import "./iface/INTokenController.sol";

//import "hardhat/console.sol";


/// @title NNRewardPool
/// @author Inf Loop - <inf-loop@nestprotocol.org>
/// @author Paradox  - <paradox@nestprotocol.org>

/// @dev The contract is for bookkeeping ETH, NEST and Tokens. It is served as a vault, such that 
///     assets are transferred internally to save GAS.
contract NestPool is INestPool {
    
    using address_make_payable for address;
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    uint8 private flag;  // 0: UNINITIALIZED  | 1: INITIALIZED
    uint256 minedNestAmount; 

    address override public governance;
    address public addrOfNestBurning = address(0x1);

    // Contracts 
    address public C_NestDAO;
    address public C_NestMining;
    ERC20   public C_NestToken;
    address public C_NTokenController;
    address public C_NNToken;
    address public C_NNRewardPool;
    address public C_NestStaking;
    address public C_NestQuery;

    // eth ledger for all miners, if address == 0, it is the balance of pool
    mapping(address => uint256) _eth_ledger;
    // token => miner => amount 
    mapping(address => mapping(address => uint256)) _token_ledger;

    // mapping(address => uint256) _nest_ledger;

    mapping(address => address) _token_ntoken_mapping;

    // parameters 

    constructor() public 
    {
        governance = msg.sender;
    }

    receive() external payable { }

    /* ========== MODIFIERS ========== */

    modifier onlyGovernance() 
    {
        require(msg.sender == governance, "Nest:Pool:!governance");
        _;
    }

    modifier onlyBy(address _contract) 
    {
        require(msg.sender == _contract, "Nest:Pool:!Auth");
        _;
    }

    modifier onlyGovOrBy(address _contract) 
    {
        require(msg.sender == governance || msg.sender == _contract, "Nest:Pool:!Auth");
        _;
    }

    modifier onlyGovOrBy2(address _contract, address _contract2)
    {
        require(msg.sender == governance || msg.sender == _contract || msg.sender == _contract2, "Nest:Pool:!Auth");
        _;
    }

    modifier onlyGovOrBy3(address _contract1, address _contract2, address _contract3)
    {
        require(msg.sender == governance
            || msg.sender == _contract1
            || msg.sender == _contract2
            || msg.sender == _contract3, "Nest:Pool:!Auth");
        _;
    }

    modifier onlyGovOrByNest()
    {
        require(msg.sender == governance 
            || msg.sender == C_NestMining
            || msg.sender == C_NTokenController 
            || msg.sender == C_NestDAO 
            || msg.sender == C_NestStaking 
            || msg.sender == C_NNRewardPool 
            || msg.sender == C_NestQuery, "Nest:Pool:!Auth");
        _;
    }

    modifier onlyMiningContract()
    {
        require(address(msg.sender) == C_NestMining, "Nest:Pool:onlyMining");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function setGovernance(address _gov) 
        override external onlyGovernance 
    { 
        governance = _gov;
    }

    function setContracts(
            address NestToken, address NestMining, 
            address NestStaking, address NTokenController, 
            address NNToken, address NNRewardPool, 
            address NestQuery, address NestDAO
        ) 
        external onlyGovernance
    {
        if (NestToken != address(0)) {
            C_NestToken = ERC20(NestToken);
        }
        if (NestMining != address(0)) {
            C_NestMining = NestMining;
        }
        if (NTokenController != address(0)) {
            C_NTokenController = NTokenController;
        }
        if (NNToken != address(0)) {
            C_NNToken = NNToken;
        }
        if (NNRewardPool != address(0)) {
            C_NNRewardPool = NNRewardPool;
        }
        if (NestStaking != address(0)) {
            C_NestStaking = NestStaking;
        }
        if (NestQuery != address(0)) {
            C_NestQuery = NestQuery;
        }
        if (NestDAO != address(0)) {
            C_NestDAO = NestDAO;
        }

        INestMining(C_NestMining).loadContracts();
        INestStaking(C_NestStaking).loadContracts();
        INNRewardPool(C_NNRewardPool).loadContracts();
        INTokenController(C_NTokenController).loadContracts();
        INestQuery(C_NestQuery).loadContracts();
        INestDAO(C_NestDAO).loadContracts();
    }

    function getNTokenFromToken(address token) 
        override view public returns (address) 
    {
        return _token_ntoken_mapping[token];
    }

    function setNTokenToToken(address token, address ntoken) 
        override 
        public
        onlyGovOrBy(C_NTokenController) 
    {
        _token_ntoken_mapping[token] = ntoken;
        _token_ntoken_mapping[ntoken] = ntoken;
    }

    /* ========== ONLY FOR EMERGENCY ========== */

    function drainEth(address to, uint256 amount) 
        external onlyGovernance
    {
        TransferHelper.safeTransferETH(to, amount);
    }

    function drainNest(address to, uint256 amount) 
        external onlyGovernance
    {
        require(C_NestToken.transfer(to, amount),"Nest:Pool:!transfer");
    }

    function drainToken(address token, address to, uint256 amount) 
        external onlyGovernance
    {
        ERC20(token).safeTransfer(to, amount);
    }

    function transferNestInPool(address from, address to, uint256 amount) 
        external onlyGovernance
    {
        if (amount == 0) {
            return;
        }
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];
        uint256 blnc = _nest_ledger[from];
        require (blnc >= amount, "Nest:Pool:!amount");
        _nest_ledger[from] = blnc.sub(amount);
        _nest_ledger[to] = _nest_ledger[to].add(amount);
    }

    function transferTokenInPool(address token, address from, address to, uint256 amount) 
        external onlyGovernance
    {
        if (amount == 0) {
            return;
        }
        uint256 blnc = _token_ledger[token][from];
        require (blnc >= amount, "Nest:Pool:!amount");
        _token_ledger[token][from] = blnc.sub(amount);
        _token_ledger[token][to] = _token_ledger[token][to].add(amount);
    }
/*
    function transferEthInPool(address token, address from, address to, uint256 amount) 
        external onlyGovernance
    {
        uint256 blnc = _eth_ledger[from];
        require (amount > 0 && blnc >= amount, "Nest:Pool:!amount");
        _eth_ledger[from] = blnc.sub(amount);
        _eth_ledger[to] = _eth_ledger[to].add(amount);
    }
*/


    /* ========== FREEZING/UNFREEZING ========== */

    // NOTE: Guarded by onlyMiningContract

    function freezeEth(address miner, uint256 ethAmount) 
        override public onlyGovOrBy(C_NestMining) 
    {
        // emit LogAddress("freezeEthAndToken> miner", miner);
        // emit LogAddress("freezeEthAndToken> token", token);
        uint256 blncs = _eth_ledger[miner];
        require(blncs >= ethAmount, "Nest:Pool:BAL(eth)<0");
        _eth_ledger[miner] = blncs - ethAmount;  //safe_math: checked before
        _eth_ledger[address(this)] =  _eth_ledger[address(this)].add(ethAmount);
    }

    function unfreezeEth(address miner, uint256 ethAmount) 
        override public onlyGovOrBy(C_NestMining)  
    {
        if (ethAmount > 0) {
            // LogUint("unfreezeEthAndToken> _eth_ledger[address(0x0)]", _eth_ledger[address(0x0)]);
            // LogUint("unfreezeEthAndToken> _eth_ledger[miner]", _eth_ledger[miner]);
            // LogUint("unfreezeEthAndToken> ethAmount", ethAmount);
            _eth_ledger[address(this)] =  _eth_ledger[address(this)].sub(ethAmount);
            _eth_ledger[miner] = _eth_ledger[miner].add(ethAmount);
        } 
    }

    function freezeNest(address miner, uint256 nestAmount) 
        override public onlyGovOrBy(C_NestMining)  
    {
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];

        uint256 blncs = _nest_ledger[miner];
        
        _nest_ledger[address(this)] =  _nest_ledger[address(this)].add(nestAmount);

        if (blncs < nestAmount) {
            _nest_ledger[miner] = 0; 
            require(C_NestToken.transferFrom(miner,  address(this), nestAmount - blncs), "Nest:Pool:!transfer"); //safe math
        } else {
            _nest_ledger[miner] = blncs - nestAmount;  //safe math
        }
    }

    function unfreezeNest(address miner, uint256 nestAmount) 
        override public onlyGovOrBy(C_NestMining)  
    {
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];

        if (nestAmount > 0) {
            _nest_ledger[address(this)] =  _nest_ledger[address(this)].sub(nestAmount);
            _nest_ledger[miner] = _nest_ledger[miner].add(nestAmount); 
        }
    }

    function freezeToken(address miner, address token, uint256 tokenAmount) 
        override external onlyGovOrBy(C_NestMining)  
    {
        uint256 blncs = _token_ledger[token][miner];
        _token_ledger[token][address(this)] =  _token_ledger[token][address(this)].add(tokenAmount);
        if (blncs < tokenAmount) {
            _token_ledger[token][miner] = 0; 
            ERC20(token).safeTransferFrom(address(miner),  address(this), tokenAmount - blncs); //safe math
        } else {
            _token_ledger[token][miner] = blncs - tokenAmount;  //safe math
        }
    }

    function unfreezeToken(address miner, address token, uint256 tokenAmount) 
        override external onlyGovOrBy(C_NestMining)  
    {
        if (tokenAmount > 0) {
            _token_ledger[token][address(this)] =  _token_ledger[token][address(this)].sub(tokenAmount);
            _token_ledger[token][miner] = _token_ledger[token][miner].add(tokenAmount); 
        }
    }

    function freezeEthAndToken(address miner, uint256 ethAmount, address token, uint256 tokenAmount) 
        override external onlyGovOrBy(C_NestMining)  
    {
        uint256 blncs = _eth_ledger[miner];
        require(blncs >= ethAmount, "Nest:Pool:!eth");
        _eth_ledger[miner] = blncs - ethAmount;  //safe_math: checked before
        _eth_ledger[address(this)] =  _eth_ledger[address(this)].add(ethAmount);

        blncs = _token_ledger[token][miner];
        _token_ledger[token][address(this)] =  _token_ledger[token][address(this)].add(tokenAmount);
        if (blncs < tokenAmount) {
            _token_ledger[token][miner] = 0;
            ERC20(token).safeTransferFrom(address(miner),  address(this), tokenAmount - blncs); //safe math
        } else {
            _token_ledger[token][miner] = blncs - tokenAmount;  //safe math
        }
    }

    function unfreezeEthAndToken(address miner, uint256 ethAmount, address token, uint256 tokenAmount) 
        override external onlyGovOrBy(C_NestMining)  
    {
        if (ethAmount > 0) {
            _eth_ledger[address(this)] =  _eth_ledger[address(this)].sub(ethAmount);
            _eth_ledger[miner] = _eth_ledger[miner].add(ethAmount);
        } 

        if (tokenAmount > 0) {
            _token_ledger[token][address(this)] =  _token_ledger[token][address(this)].sub(tokenAmount);
            _token_ledger[token][miner] = _token_ledger[token][miner].add(tokenAmount); 
        }
    }

    /* ========== BALANCE ========== */


    function balanceOfNestInPool(address miner) 
        override public view returns (uint256)
    {
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];

        return _nest_ledger[miner];
    }

    function balanceOfEthInPool(address miner) 
        override public view returns (uint256)
    {
        return _eth_ledger[miner];
    }

    function balanceOfTokenInPool(address miner, address token) 
        override public view returns (uint256)
    {
        return _token_ledger[token][miner];
    }

    function balanceOfEthFreezed() public view returns (uint256)
    {
        return _eth_ledger[address(0x0)];
    }

    function balanceOfTokenFreezed(address token) public view returns (uint256)
    {
        return _token_ledger[token][address(0x0)];
    }

    /* ========== DISTRIBUTING ========== */

    function addNest(address miner, uint256 amount) 
        override public onlyGovOrBy(C_NestMining)
    {
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];
        _nest_ledger[miner] = _nest_ledger[miner].add(amount);
        minedNestAmount = minedNestAmount.add(amount);
    }

    function addNToken(address miner, address ntoken, uint256 amount) 
        override public onlyGovOrBy(C_NestMining)
    {
        _token_ledger[ntoken][miner] = _token_ledger[ntoken][miner].add(amount);
    }

    /* ========== DEPOSIT ========== */

    // NOTE: Guarded by onlyMiningContract

    function depositEth(address miner) 
        override payable external onlyGovOrBy(C_NestMining) 
    {
        _eth_ledger[miner] =  _eth_ledger[miner].add(msg.value);
    }

    /* ========== WITHDRAW ========== */

    // NOTE: Guarded by onlyGovOrBy(C_NestMining), onlyGovOrBy(C_NestStaking)
    
    /// @dev If amount == 0, it won't go stuck
    function withdrawEth(address miner, uint256 ethAmount) 
        override public onlyGovOrByNest
    {
        uint256 blncs = _eth_ledger[miner];
        require(ethAmount <= blncs, "Nest:Pool:(ethAmount)<BAL");
        if (ethAmount > 0) {
            _eth_ledger[miner] = blncs - ethAmount; // safe math
            TransferHelper.safeTransferETH(miner, ethAmount);
        }
    }

    /// @dev If amount == 0, it won't go stuck
    function withdrawToken(address miner, address token, uint256 tokenAmount) 
        override public onlyGovOrByNest
    {
        uint256 blncs = _token_ledger[token][miner];
        require(tokenAmount <= blncs, "Nest:Pool:(tokenAmount)<BAL");
        if (tokenAmount > 0) {
            _token_ledger[token][miner] = blncs - tokenAmount; // safe math
            ERC20(token).safeTransfer(miner, tokenAmount);
        }
    }

    /// @dev If amount == 0, it won't go stuck
    function withdrawNToken(address miner, address ntoken, uint256 amount) 
        override public onlyGovOrByNest
    {
        uint256 blncs = _token_ledger[ntoken][miner];
        require(amount <= blncs, "Nest:Pool:(ntokenAmount)<BAL");
        if (amount > 0) {
            _token_ledger[ntoken][miner]= blncs - amount;
            require(ERC20(ntoken).transfer(miner, amount), "Nest:Pool:!transfer");
        }
    }

    /// @dev If amount == 0, it won't go stuck
    function withdrawNest(address miner, uint256 amount) 
        override public onlyGovOrByNest
    {
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];

        uint256 blncs = _nest_ledger[miner];
        require(amount <= blncs, "Nest:Pool:(nestAmount)<BAL");
        if (amount > 0) {
            _nest_ledger[miner] = blncs - amount;  // safe math
            require(C_NestToken.transfer(miner, amount),"Nest:Pool:!transfer");
        }
    }


    /// @dev If amount == 0, it won't go stuck
    function withdrawEthAndToken(address miner, uint256 ethAmount, address token, uint256 tokenAmount) 
        override public onlyGovOrBy(C_NestMining)
    {
        uint256 blncs = _eth_ledger[miner];
        if (ethAmount <= blncs && ethAmount > 0) {
            _eth_ledger[miner] = blncs - ethAmount;  // safe math
            TransferHelper.safeTransferETH(miner, ethAmount);
        }

        blncs = _token_ledger[token][miner];
        if (tokenAmount <= blncs && tokenAmount > 0) {
            _token_ledger[token][miner] = blncs - tokenAmount;  // safe math
            ERC20(token).safeTransfer(miner, tokenAmount);
        }
    }

    /// @dev If amount == 0, it won't go stuck
    function withdrawNTokenAndTransfer(address miner, address ntoken, uint256 amount, address to) 
        override public onlyGovOrBy(C_NestStaking)
    {
        uint256 blncs = _token_ledger[ntoken][miner];
        require(amount <= blncs, "Nest:Pool:(nestAmount)<BAL");
        if (amount > 0) {
            _token_ledger[ntoken][miner] = blncs - amount;  // safe math
            require(ERC20(ntoken).transfer(to, amount),"Nest:Pool:!transfer");
        }
    }

    /* ========== HELPERS (VIEWS) ========== */
        
    function assetsList(uint256 len, address[] memory tokenList) 
        public view returns (uint256[] memory) 
    {
        uint256[] memory list = new uint256[](len);
        list[0] = _eth_ledger[address(msg.sender)];
        for (uint i = 0; i < len; i++) {
            address _token = tokenList[i];
            list[i+1] = _token_ledger[_token][address(msg.sender)];
        }
        return list;
    }

    function addrOfNestMining() override public view returns (address) 
    {
        return C_NestMining;
    }

    function addrOfNestToken() override public view returns (address) 
    {
        return address(C_NestToken);
    }

    function addrOfNTokenController() override public view returns (address) 
    {
        return C_NTokenController;
    }
    
    function addrOfNNRewardPool() override public view returns (address) 
    {
        return C_NNRewardPool;
    }

    function addrOfNNToken() override public view returns (address) 
    {
        return C_NNToken;
    }

    function addrOfNestStaking() override public view returns (address) 
    {
        return C_NestStaking;
    }

    function addrOfNestQuery() override public view returns (address) 
    {
        return C_NestQuery;
    }

    function addrOfNestDAO() override public view returns (address) 
    {
        return C_NestDAO;
    }

    function addressOfBurnedNest() override public view returns (address) 
    {
        return addrOfNestBurning;
    }

    // function getMinerNToken(address miner, address token) public view returns (uint256 tokenAmount) 
    // {
    //     if (token != address(0x0)) {
    //         tokenAmount = _token_ledger[token][miner];
    //     }
    // } 
        
    function getMinerEthAndToken(address miner, address token) 
        public view returns (uint256 ethAmount, uint256 tokenAmount) 
    {
        ethAmount = _eth_ledger[miner];
        if (token != address(0x0)) {
            tokenAmount = _token_ledger[token][miner];
        }
    } 

    function getMinerNest(address miner) public view returns (uint256 nestAmount) 
    {
        mapping(address => uint256) storage _nest_ledger = _token_ledger[address(C_NestToken)];

        nestAmount = _nest_ledger[miner];
    } 

}
