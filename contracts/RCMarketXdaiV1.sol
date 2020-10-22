pragma solidity 0.5.13;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC721/ERC721Full.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/upgrades/contracts/Initializable.sol";
import "@nomiclabs/buidler/console.sol";
import "./interfaces/IRealitio.sol";
import "./interfaces/IFactory.sol";
import "./interfaces/ITreasury.sol";

/// @title Reality Cards Market
/// @author Andrew Stanger

contract RCMarketXdaiV1 is Ownable, ERC721Full {

    using SafeMath for uint256;

    ////////////////////////////////////
    //////// VARIABLES /////////////////
    ////////////////////////////////////

    ///// CONTRACT SETUP /////
    /// @dev = how many outcomes/teams/NFTs etc 
    uint256 public numberOfTokens;
    /// @dev counts how many NFTs have been minted 
    /// @dev when nftMintCount = numberOfTokens, increment state
    uint256 public nftMintCount;
    /// @dev the question ID of the question on realitio
    bytes32 public questionId;
    /// @dev only for _revertToPreviousOwner to prevent gas limits
    uint256 public constant MAX_ITERATIONS = 10;
    enum States {NFTSNOTMINTED, OPEN, LOCKED, WITHDRAW}
    States public state; 

    ///// CONTRACT VARIABLES /////
    IRealitio public realitio;
    ICash public cash;
    ITreasury public treasury;

    ///// PRICE, DEPOSITS, RENT /////
    /// @dev in attodai (so $100 = 100000000000000000000)
    mapping (uint256 => uint256) public price; 
    /// @dev keeps track of all the rent paid by each user. So that it can be returned in case of an invalid market outcome.
    mapping (address => uint256) public collectedPerUser;
    /// @dev keeps track of all the rent paid for each token, front end only
    mapping (uint256 => uint256) public collectedPerToken;
    /// @dev an easy way to track the above across all tokens
    uint256 public totalCollected; 
    /// @dev tells the contract to exit position after ten mins deposit used
    /// @dev user => tokenId => bool
    mapping (address => mapping (uint256 => bool)) public exitFlag;
 
    ///// TIME /////
    /// @dev how many seconds each user has held each token for, for determining winnings  
    mapping (uint256 => mapping (address => uint256) ) public timeHeld;
    /// @dev sums all the timeHelds for each. Not required, but saves on gas when paying out. Should always increment at the same time as timeHeld
    mapping (uint256 => uint256) public totalTimeHeld; 
    /// @dev used to determine the rent due. Rent is due for the period (now - timeLastCollected), at which point timeLastCollected is set to now.
    mapping (uint256 => uint256) public timeLastCollected; 
    /// @dev when a token was bought. Used to enforce minimum of one hour rental, also used in front end. Rent collection does not need this, only needs timeLastCollected.
    mapping (uint256 => uint256) public timeAcquired; 
     /// @dev to track the max timeheld of each token (for giving NFT to winner)
    mapping (uint256 => uint256) public maxTimeHeld;
    /// @dev to track who has owned it the most (for giving NFT to winner)
    mapping (uint256 => address) public longestOwner;

    ///// PREVIOUS OWNERS /////
    /// @dev keeps track of all previous owners of a token, including the price, so that if the current owner's deposit runs out,
    /// @dev ...ownership can be reverted to a previous owner with the previous price. Index 0 is NOT used, this tells the contract to foreclose.
    /// @dev this does NOT keep a reliable list of all owners, if it reverts to a previous owner then the next owner will overwrite the owner that was in that slot.
    mapping (uint256 => mapping (uint256 => rental) ) public ownerTracker;  
    /// @dev tracks the position of the current owner in the ownerTracker mapping
    mapping (uint256 => uint256) public currentOwnerIndex; 
    /// @dev the struct for ownerTracker
    struct rental { address owner;
                    uint256 price; }

    ///// MARKET RESOLUTION VARIABLES /////
    uint256 public winningOutcome; 
    //// @dev when the market locks 
    uint32 public marketLockingTime; 
    //// @dev when the question can be answered on realitio
    uint32 public oracleResolutionTime;
    /// @dev prevent users withdrawing twice
    mapping (address => bool) public userAlreadyWithdrawn;

    // WORK TO DO 
    // add new state for not open, update the 'incorrect state' tests
    // update check state modifier to move the state if timestmps are right
    // set exit flag to zero after certain amount of itme, so that they can set how long to own it for
    // update to latest version of solidity etc [why, what is the point?]
    // create an owned function in treasury to change the factory address
    // maybe: add variable for min% increase so it can be changed

    

    ////////////////////////////////////
    //////// CONSTRUCTOR ///////////////
    ////////////////////////////////////

    function initialize(
        address _owner,
        uint256 _numberOfTokens, 
        uint32 _marketLockingTime,
        uint32 _oracleResolutionTime, 
        uint256 _templateId, 
        string memory _question, 
        address _arbitrator, 
        uint32 _timeout,
        string memory _tokenName
    ) public initializer {
        // initialiiize!
        Ownable.initialize(_owner);
        ERC721.initialize();
        ERC721Metadata.initialize(_tokenName,"RC");
        winningOutcome = 2**256 - 1; // default invalid
        
        // resolution time must not be less than locking time, and not greater by more than one week
        require(_marketLockingTime + 1 weeks > _oracleResolutionTime && _marketLockingTime <= _oracleResolutionTime, "Invalid timestamps" );

        // assign arguments to public variables
        numberOfTokens = _numberOfTokens;
        marketLockingTime = _marketLockingTime;
        oracleResolutionTime = _oracleResolutionTime;
        
        // external contract variables:
        IFactory _factory = IFactory(msg.sender);
        realitio = _factory.realitio();
        treasury = _factory.treasury();
        assert(address(realitio) != address(0));
        assert(address(treasury) != address(0));

        // create the question on Realitio
        /// @dev temporarily removing this
        _question;
        _templateId;
        _arbitrator;
        _timeout;
        // questionId = _postQuestion(_templateId, _question, _arbitrator, _timeout, _oracleResolutionTime, 0);
    } 

    ////////////////////////////////////
    //////// EVENTS ////////////////////
    ////////////////////////////////////

    event LogNewRental(address indexed newOwner, uint256 indexed newPrice, uint256 indexed tokenId);
    event LogPriceChange(uint256 indexed newPrice, uint256 indexed tokenId);
    event LogForeclosure(address indexed prevOwner, uint256 indexed tokenId);
    event LogRentCollection(uint256 indexed rentCollected, uint256 indexed tokenId, address indexed owner);
    event LogReturnToPreviousOwner(uint256 indexed tokenId, address indexed previousOwner);
    event LogContractLocked(bool indexed didTheEventFinish);
    event LogWinnerKnown(uint256 indexed winningOutcome);
    event LogWinningsPaid(address indexed paidTo, uint256 indexed amountPaid);
    event LogRentReturned(address indexed returnedTo, uint256 indexed amountReturned);
    event LogTimeHeldUpdated(uint256 indexed newTimeHeld, address indexed owner, uint256 indexed tokenId);
    event LogStateChange(uint256 indexed newState);

    ////////////////////////////////////
    //////// INITIAL SETUP /////////////
    ////////////////////////////////////

    function mintNfts(string calldata _uri) external checkState(States.NFTSNOTMINTED) {
        _mint(address(this), nftMintCount); 
        _setTokenURI(nftMintCount, _uri);
        nftMintCount = nftMintCount.add(1);
        if (nftMintCount == numberOfTokens) {
            _incrementState();
        }
    }

    ////////////////////////////////////
    /////////// MODIFIERS //////////////
    ////////////////////////////////////

    modifier checkState(States currentState) {
        require(state == currentState, "Incorrect state");
        _;
    }

    /// @notice checks the token exists
    modifier tokenExists(uint256 _tokenId) {
        require(_tokenId < numberOfTokens, "This token does not exist");
       _;
    }

    /// @notice what it says on the tin
    modifier amountNotZero(uint256 _dai) {
        require(_dai > 0, "Amount must be above zero");
       _;
    }

    /// @notice what it says on the tin
    modifier onlyTokenOwner(uint256 _tokenId) {
        require(msg.sender == ownerOf(_tokenId), "Not owner");
       _;
    }

    ////////////////////////////////////
    ////// REALITIO CONTRACT CALLS /////
    ////////////////////////////////////

    /// @notice posts the question to realit.io
    function _postQuestion(uint256 template_id, string memory question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce) internal returns (bytes32) {
        return realitio.askQuestion(template_id, question, arbitrator, timeout, opening_ts, nonce);
    }

    /// @notice gets an existing question's content hash
    function _getHashExistingQuestion(bytes32 _questionId) internal view returns (bytes32) {
        return realitio.getContentHash(_questionId);
    }

    /// @notice gets the winning outcome from realitio
    /// @dev the returned value is equivilent to tokenId
    /// @dev this function call will revert if it has not yet resolved
    function _getWinner() internal view returns(uint256) {
        bytes32 _winningOutcome = realitio.resultFor(questionId);
        return uint256(_winningOutcome);
    }

    /// @notice has the question been finalized on realitio?
    function _isQuestionFinalized() internal view returns (bool) {
        return realitio.isFinalized(questionId);
    }

    ////////////////////////////////////
    //// MARKET RESOLUTION FUNCTIONS ///
    ////////////////////////////////////

    /// @notice checks whether the competition has ended (1 hour grace), if so moves to LOCKED state
    /// @dev can be called by anyone 
    function lockMarket() external checkState(States.OPEN) {
        require(marketLockingTime < (now - 1 hours), "Market has not finished");
        // do a final rent collection before the contract is locked down
        collectRentAllTokens();
        _incrementState();
        emit LogContractLocked(true);
    }

    /// @notice checks whether the Realitio question has resolved, and if yes, gets the winner
    /// @dev can be called by anyone 
    function determineWinner() external checkState(States.LOCKED) {
        require(_isQuestionFinalized() == true, "Oracle not resolved");
        // get the winner. This will revert if answer is not resolved.
        winningOutcome = _getWinner();
        _incrementState();
        _processNFTsAfterEvent();
        emit LogWinnerKnown(winningOutcome);
    }

    /// @notice pays out winnings, or returns funds
    /// @dev public because called by withdrawWinningsAndDeposit
    function withdraw() public checkState(States.WITHDRAW) {
        require(!userAlreadyWithdrawn[msg.sender], "Already withdrawn");
        userAlreadyWithdrawn[msg.sender] = true;
        if (totalTimeHeld[winningOutcome] > 0) {
            _payoutWinnings();
        } else {
             _returnRent();
        }
    }

    /// @notice pays winnings
    function _payoutWinnings() internal {
        uint256 _winnersTimeHeld = timeHeld[winningOutcome][msg.sender];
        uint256 _numerator = totalCollected.mul(_winnersTimeHeld);
        uint256 _winningsToTransfer = _numerator.div(totalTimeHeld[winningOutcome]); 
        require(_winningsToTransfer > 0, "Not a winner");
        treasury.payout(msg.sender, _winningsToTransfer);
        emit LogWinningsPaid(msg.sender, _winningsToTransfer);
    }

    /// @notice returns all funds to users in case of invalid outcome
    function _returnRent() internal {
        uint256 _rentCollected = collectedPerUser[msg.sender];
        require(_rentCollected > 0, "Paid no rent");
        treasury.payout(msg.sender, _rentCollected);
        emit LogRentReturned(msg.sender, _rentCollected);
    }

    ////////////////////////////////////
    ///// MAIN FUNCTIONS- EXTERNAL /////
    ////////////////////////////////////
    /// @dev basically functions that have checkState(States.OPEN) modifier

    /// @notice collects rent for all tokens
    /// @dev cannot be external because it is called within the lockContract function, therefore public
    function collectRentAllTokens() public checkState(States.OPEN) {
       for (uint i = 0; i < numberOfTokens; i++) {
            _collectRent(i);
        }
    }

    /// @notice rent every Card at the minimum price
    function rentAllCards() external checkState(States.OPEN)  {
        for (uint i = 0; i < numberOfTokens; i++) {
            if (ownerOf(i) != msg.sender) {
                uint _newPrice;
                if (price[i]>0) {
                    _newPrice = price[i].mul(11).div(10);
                }
                newRental(_newPrice, i);
            }
        }
    }
    
    /// @notice to rent a token
    function newRental(uint256 _newPrice, uint256 _tokenId) public checkState(States.OPEN) tokenExists(_tokenId) {
        require(_newPrice >= price[_tokenId].mul(11).div(10), "Price not 10% higher");
        require(_newPrice >= 1 ether, "Minimum rental 1 Dai");
        collectRentAllTokens();

        address _currentOwner = ownerOf(_tokenId);

        if (_currentOwner == msg.sender) { 
            // bought by current owner- just change price
            price[_tokenId] = _newPrice;
            ownerTracker[_tokenId][currentOwnerIndex[_tokenId]].price = _newPrice;
        } else {   
            // allocate 10mins deposit
            treasury.allocateCardSpecificDeposit(msg.sender,_currentOwner,_tokenId,_newPrice);
            // update internals
            currentOwnerIndex[_tokenId] = currentOwnerIndex[_tokenId].add(1); 
            ownerTracker[_tokenId][currentOwnerIndex[_tokenId]].price = _newPrice;
            ownerTracker[_tokenId][currentOwnerIndex[_tokenId]].owner = msg.sender; 
            timeAcquired[_tokenId] = now;
            // externals
            _transferTokenTo(_currentOwner, msg.sender, _newPrice, _tokenId);
            emit LogNewRental(msg.sender, _newPrice, _tokenId); 
        }

        // make sure exit flag is set back to false
        if (exitFlag[msg.sender][_tokenId]) {
            exitFlag[msg.sender][_tokenId] = false;
        }
    }

    /// @notice stop renting a token
    /// @dev public because called by exitAll()
    /// @dev doesn't need to be current owner so user can prevent ownership returning to them
    function exit(uint256 _tokenId) public checkState(States.OPEN) {
        if (!exitFlag[msg.sender][_tokenId]) {
            exitFlag[msg.sender][_tokenId] = true;
            _collectRent(_tokenId);
        }
    }

    /// @notice stop renting all tokens
    function exitAll() external {
        for (uint i = 0; i < numberOfTokens; i++) {
            exit(i);
        }
    }

    /// @notice ability to add liqudity to the pot without being able to win. 
    function sponsor() external payable {
        require(msg.value > 0, "Must send something");
        require(state != States.LOCKED, "Incorrect state");
        require(state != States.WITHDRAW, "Incorrect state");
        // send funds to the Treasury
        address _thisAddressNotPayable = address(treasury);
        address payable _recipient = address(uint160(_thisAddressNotPayable));
        (bool _success, bytes memory data) = _recipient.call.value(msg.value)("");
        require(_success, "Transfer failed");
        data; // suppress compilation warning
        totalCollected = totalCollected.add(msg.value);
        // just so user can get it back if invalid outcome
        collectedPerUser[msg.sender] = collectedPerUser[msg.sender].add(msg.value); 
    }

    ////////////////////////////////////
    ///// MAIN FUNCTIONS- INTERNAL /////
    ////////////////////////////////////

    /// @notice collects rent for a specific token
    /// @dev also calculates and updates how long the current user has held the token for
    /// @dev is not a problem if called externally, but making internal over public to save gas
    function _collectRent(uint256 _tokenId) internal {
        uint256 _timeOfThisCollection = now;

        //only collect rent if the token is owned (ie, if owned by the contract this implies unowned)
        if (ownerOf(_tokenId) != address(this)) {
            
            uint256 _rentOwed = price[_tokenId].mul(now.sub(timeLastCollected[_tokenId])).div(1 days);
            address _currentOwner = ownerOf(_tokenId);
            uint256 _cardSpecificDeposit = treasury.cardSpecificDeposits(address(this),_currentOwner,_tokenId);
            uint256 _totalDeposit = treasury.deposits(_currentOwner).add(_cardSpecificDeposit);
            bool _exitFlag = exitFlag[_currentOwner][_tokenId];
            
            if (!_exitFlag) {
                if (_rentOwed >= _totalDeposit) {
                    // run out of deposit. Calculate time it was actually paid for, then revert to previous owner 
                    _timeOfThisCollection = timeLastCollected[_tokenId].add(((now.sub(timeLastCollected[_tokenId])).mul(_totalDeposit).div(_rentOwed)));
                    _rentOwed = _totalDeposit; // take what's left     
                    _revertToPreviousOwner(_tokenId);
                } 
            } else {
                if (_rentOwed >= _cardSpecificDeposit) {
                    // run out of deposit. Calculate time it was actually paid for, then revert to previous owner 
                    _timeOfThisCollection = timeLastCollected[_tokenId].add(((now.sub(timeLastCollected[_tokenId])).mul(_cardSpecificDeposit).div(_rentOwed)));
                    _rentOwed = _cardSpecificDeposit; // take what's left     
                    _revertToPreviousOwner(_tokenId);
                } 
            }
            // _rentOwed will be 0 if _exitFlag set after cardSpecificDeposit used
            if (_rentOwed > 0) {
                // decrease deposit by rent owed at the Treasury
                treasury.payRent(_currentOwner, _rentOwed, _tokenId, _exitFlag);
                // update time held and amount collected variables
                uint256 _timeHeldToIncrement = (_timeOfThisCollection.sub(timeLastCollected[_tokenId]));
                // note that if _revertToPreviousOwner was called above, _currentOwner will no longer refer to the
                // ... actual current owner. This is correct- we are updating the variables of the user who just
                // ... had their rent collected, not the new owner, if there is one
                timeHeld[_tokenId][_currentOwner] = timeHeld[_tokenId][_currentOwner].add(_timeHeldToIncrement);
                totalTimeHeld[_tokenId] = totalTimeHeld[_tokenId].add(_timeHeldToIncrement);
                collectedPerUser[_currentOwner] = collectedPerUser[_currentOwner].add(_rentOwed);
                collectedPerToken[_tokenId] = collectedPerToken[_tokenId].add(_rentOwed);
                totalCollected = totalCollected.add(_rentOwed);

                // longest owner tracking
                if (timeHeld[_tokenId][_currentOwner] > maxTimeHeld[_tokenId]) {
                    maxTimeHeld[_tokenId] = timeHeld[_tokenId][_currentOwner];
                    longestOwner[_tokenId] = _currentOwner;
                }

                emit LogTimeHeldUpdated(timeHeld[_tokenId][_currentOwner], _currentOwner, _tokenId);
                emit LogRentCollection(_rentOwed, _tokenId, _currentOwner);
            } 
        }

        // timeLastCollected is updated regardless of whether the token is owned, so that the clock starts ticking
        // ... when the first owner buys it, because this function is run before ownership changes upon calling newRental
        timeLastCollected[_tokenId] = _timeOfThisCollection;
    }

    /// @notice if a users deposit runs out, either return to previous owner or foreclose
    function _revertToPreviousOwner(uint256 _tokenId) internal {
        uint256 _index;
        address _previousOwner;
        uint256 _previousOwnersDeposit;

        // loop max ten times before just assigning it to that owner, to prevent block limit
        for (uint i=0; i < MAX_ITERATIONS; i++)  {
            currentOwnerIndex[_tokenId] = currentOwnerIndex[_tokenId].sub(1); // currentOwnerIndex will now point to  previous owner
            _index = currentOwnerIndex[_tokenId]; // just for readability
            _previousOwner = ownerTracker[_tokenId][_index].owner;
            if (exitFlag[_previousOwner][_tokenId]) {
                _previousOwnersDeposit = treasury.cardSpecificDeposits(address(this),msg.sender,_tokenId);
            } else {
                _previousOwnersDeposit = treasury.deposits(_previousOwner).add(treasury.cardSpecificDeposits(address(this),msg.sender,_tokenId));
            }

            // if no previous owners. price -> zero, foreclose
            if (_index == 0) {
                _foreclose(_tokenId);
                break;
            } else if (_previousOwnersDeposit > 0) {
                break;
            }  
        }   

        // if the above loop did not end in foreclose, then transfer to previous owner
        if (ownerOf(_tokenId) != address(this)) {
            // transfer to previous owner
            address _currentOwner = ownerOf(_tokenId);
            uint256 _oldPrice = ownerTracker[_tokenId][_index].price;
            _transferTokenTo(_currentOwner, _previousOwner, _oldPrice, _tokenId);
            emit LogReturnToPreviousOwner(_tokenId, _previousOwner);
        }
    }

    /// @notice gives the winning Card to the winner, burns the rest
    function _processNFTsAfterEvent() internal {
        for (uint i = 0; i < numberOfTokens; i++) {
            if (i == winningOutcome && longestOwner[i] != address(0)) {
                // if never owned, longestOwner[i] will = zero
                _transferTokenTo(ownerOf(i), longestOwner[i], price[i],i);
            } else {
                _burn(i);
            }
        }
    }

    /// @notice return token to the contract and return price to zero
    function _foreclose(uint256 _tokenId) internal {
        address _currentOwner = ownerOf(_tokenId);
        // third field is price, ie price goes to zero
        _transferTokenTo(_currentOwner, address(this), 0, _tokenId);
        emit LogForeclosure(_currentOwner, _tokenId);
    }

    /// @notice transfer ERC 721 between users
    /// @dev there is no event emitted as this is handled in ERC721.sol
    function _transferTokenTo(address _currentOwner, address _newOwner, uint256 _newPrice, uint256 _tokenId) internal {
        require(_currentOwner != address(0) && _newOwner != address(0) , "Cannot send to/from zero address");
        price[_tokenId] = _newPrice;
        _transferFrom(_currentOwner, _newOwner, _tokenId);
    }

    ////////////////////////////////////
    ///////// OTHER FUNCTIONS //////////
    ////////////////////////////////////

    /// @dev should only be called thrice
    function _incrementState() internal {
        assert(uint256(state) < 4);
        state = States(uint256(state) + 1);
        emit LogStateChange(uint256(state));
    }

    /// @dev change state to WITHDRAW to lock contract and return all funds
    /// @dev in case Oracle never resolves, or a bug is found 
    function circuitBreaker() external {
        require(now > (oracleResolutionTime + 4 weeks), "Too early");
        state = States.WITHDRAW;
        _processNFTsAfterEvent();
    }

    /// @dev transfers only possible in withdraw state, so override the existing functions
    function transferFrom(address from, address to, uint256 tokenId) public checkState(States.WITHDRAW) onlyTokenOwner(tokenId) {
        _transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) public checkState(States.WITHDRAW) onlyTokenOwner(tokenId) {
        _transferFrom(from, to, tokenId);
        _data;
    }

}
