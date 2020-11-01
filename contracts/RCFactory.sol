pragma solidity 0.5.13;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@nomiclabs/buidler/console.sol";
import './lib/CloneFactory.sol';
import "./interfaces/IRealitio.sol";
import "./interfaces/ITreasury.sol";
import './interfaces/IRCMarketXdaiV1.sol';

/// @title Reality Cards Factory
/// @author Andrew Stanger

contract RCFactory is Ownable, CloneFactory {

    using SafeMath for uint256;

    ////////////////////////////////////
    //////// VARIABLES /////////////////
    ////////////////////////////////////

    ///// CONTRACT VARIABLES /////
    IRealitio public realitio;
    ITreasury public treasury;

    ///// CONTRACT ADDRESSES /////
    // version implied by position
    mapping(uint256 => address[]) public referenceContractAddresses; 
    mapping(uint256 => address[]) public marketAddresses;
    mapping(address => bool) public mappingOfMarkets; //not currently used

    ///// MARKET PARAMETERS /////
    uint32 public realitioTimeout;
    address public arbitrator;
    uint256 public artistCut; // %
    uint256 public creatorCut; // %

    ////////////////////////////////////
    //////// EVENTS ////////////////////
    ////////////////////////////////////

    event LogMarketCreated(address contractAddress, address treasuryAddress, string[] marketDetails, string[] tokenURIs, uint32[] timestamps, uint256 mode, uint256 version, bytes ipfsHash);
    event LogNewReferenceContract(address contractAddress, uint256 mode, uint256 version);

    ////////////////////////////////////
    //////// CONSTRUCTOR ///////////////
    ////////////////////////////////////

    /// @dev Treasury must be deployed before Factory
    /// @dev Realitio address is passed for testing on mock realitio contract
    constructor(ITreasury _treasuryAddress, IRealitio _realitio) public 
    {
        treasury = _treasuryAddress;
        Ownable.initialize(msg.sender);
        assert(treasury.setFactoryAddress(address(this)));

        // initialise market parameters
        realitioTimeout = 86400; //24 hours
        realitio = IRealitio(_realitio);
        arbitrator = 0xA6EAd513D05347138184324392d8ceb24C116118; //kleros
    }

    ////////////////////////////////////
    ///////// VIEW FUNCTIONS ///////////
    ////////////////////////////////////

    function getMostRecentReferenceContract(uint256 _mode) public view returns (address) {
        return referenceContractAddresses[_mode][referenceContractAddresses[_mode].length-1];
    }

    function getAllReferenceContracts(uint256 _mode) public view returns (address[] memory) {
        return referenceContractAddresses[_mode];
    }

    function getMostRecentMarket(uint256 _mode) public view returns (address) {
        return marketAddresses[_mode][marketAddresses[_mode].length-1];
    }

    function getAllMarkets(uint256 _mode) public view returns (address[] memory) {
        return marketAddresses[_mode];
    }

    ////////////////////////////////////
    /////// REFERENCE CONTRACT /////////
    ////////////////////////////////////

    /// @notice set the reference contract for the contract logic
    /// @dev automatically increments version number if we 'upgrade' the contract
    function setReferenceContractAddress(uint256 _mode, address _referenceContractAddress) public onlyOwner {
        // check its an RC contract by reading the one constant
        IRCMarketXdaiV1 newContractVariable = IRCMarketXdaiV1(_referenceContractAddress);
        assert(newContractVariable.MAX_ITERATIONS() == 10);
        // push new reference contracts
        referenceContractAddresses[_mode].push(_referenceContractAddress);
        uint256 _version = referenceContractAddresses[_mode].length-1;
        emit LogNewReferenceContract(_referenceContractAddress, _mode, _version);
    }

    ////////////////////////////////////
    /////// MARKET PARAMETERS //////////
    ////////////////////////////////////
    /// @dev governance functions

    function updateRealitioTimeout(uint32 _newTimeout) public onlyOwner {
        require(_newTimeout >= 86400, "24 hours min");
        realitioTimeout = _newTimeout;
    }

    function updateArbitrator(address _newArbitrator) public onlyOwner {
        arbitrator = _newArbitrator;
    }

    function updateRealitioAddress(IRealitio _newRealitioAddress) public onlyOwner {
        realitio = IRealitio(_newRealitioAddress);
    }

    ////////////////////////////////////
    /////// MARKET PARAMETERS //////////
    ////////////////////////////////////

    /// @notice create a new market
    /// @param _marketDetails: [0] = token name, [1] = event name [2] = image location
    function createMarket(
        uint32 _mode,
        bytes memory _ipfsHash,
        string[] memory _marketDetails,
        uint32[] memory _timestamps,
        string[] memory _tokenURIs,
        string memory _realitioQuestion
    ) public onlyOwner returns (address)  {
        address _newAddress;

        _newAddress = createClone(getMostRecentReferenceContract(_mode));
        IRCMarketXdaiV1(_newAddress).initialize({
            _mode: _mode,
            _tokenURIs: _tokenURIs,
            _timestamps: _timestamps,
            _templateId: 2,
            _question: _realitioQuestion,
            _tokenName: _marketDetails[0]
        });
        
        assert(treasury.addMarket(_newAddress));
        marketAddresses[_mode].push(_newAddress);
        mappingOfMarkets[_newAddress] = true;
        uint256 _version = referenceContractAddresses[_mode].length-1;
        emit LogMarketCreated(address(_newAddress), address(treasury), _marketDetails, _tokenURIs, _timestamps,  _mode, _version, _ipfsHash);
        return _newAddress;
    }

}

