// SPDX-License-Identifier: UNDEFINED
pragma solidity 0.8.3;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "hardhat/console.sol";
import "./lib/NativeMetaTransaction.sol";
import "./interfaces/IRCTreasury.sol";
import "./interfaces/IRCMarket.sol";
import "./interfaces/IAlternateReceiverBridge.sol";
import "./interfaces/IRCOrderbook.sol";
import "./interfaces/IRCNftHubXdai.sol";

/// @title Reality Cards Treasury
/// @author Andrew Stanger & Daniel Chilvers
/// @notice If you have found a bug, please contact andrew@realitycards.io- no hack pls!!
contract RCTreasury is Ownable, NativeMetaTransaction, IRCTreasury {
    /*╔═════════════════════════════════╗
      ║             VARIABLES           ║
      ╚═════════════════════════════════╝*/
    /// @dev orderbook instance, to remove users bids on foreclosure
    IRCOrderbook public orderbook;
    /// @dev nfthub instance, to query current card owner
    IRCNftHubXdai public nfthub;
    /// @dev address of the alternate Receiver Bridge for withdrawals to mainnet
    address public override alternateReceiverBridgeAddress;
    /// @dev address of the Factory so only the Factory can add new markets
    address public override factoryAddress;
    /// @dev so only markets can use certain functions
    mapping(address => bool) public override isMarket;
    /// @dev sum of all deposits
    uint256 public override totalDeposits;
    /// @dev the rental payments made in each market
    mapping(address => uint256) public override marketPot;
    /// @dev sum of all market pots
    uint256 public override totalMarketPots;
    /// @dev a quick check if the market is active or not
    mapping(address => bool) public override isMarketActive;
    /// @dev rent taken and allocated to a particular market
    uint256 public marketBalance;

    /// @param deposit the users current deposit in wei
    /// @param rentalRate the daily cost of the cards the user current owns
    /// @param bidRate the sum total of all placed bids
    /// @param lastRentCalc The timestamp of the users last rent calculation
    /// @param lastRentalTime The timestamp the user last made a rental
    struct User {
        // lets pack this struct later, leaving it as uint256 for rapid development and testing
        uint256 deposit;
        uint256 rentalRate;
        uint256 bidRate;
        uint256 lastRentCalc;
        uint256 lastRentalTime;
    }
    mapping(address => User) public user;

    /*╔═════════════════════════════════╗
      ║      GOVERNANCE VARIABLES       ║
      ╚═════════════════════════════════╝*/
    /// @dev only parameters that need to be are here, the rest are in the Factory
    /// @dev minimum rental duration (1 day divisor: i.e. 24 = 1 hour, 48 = 30 mins)
    uint256 public override minRentalDayDivisor;
    /// @dev max deposit balance, to minimise funds at risk
    uint256 public override maxContractBalance;
    /// @dev the maximum number of bids a user is allowed
    uint256 public maxBidCountLimit;

    /*╔═════════════════════════════════╗
      ║             SAFETY              ║
      ╚═════════════════════════════════╝*/
    /// @dev if true, cannot deposit, withdraw or rent any cards across all events
    bool public override globalPause;
    /// @dev if true, cannot rent any cards for specific market
    mapping(address => bool) public override marketPaused;

    /*╔═════════════════════════════════╗
      ║            UBER OWNER           ║
      ╚═════════════════════════════════╝*/
    /// @dev high level owner who can change the factory address
    address public override uberOwner;

    /*╔═════════════════════════════════╗
      ║             EVENTS              ║
      ╚═════════════════════════════════╝*/

    event LogDepositIncreased(
        address indexed sentBy,
        uint256 indexed daiDeposited
    );
    event LogDepositWithdrawal(
        address indexed returnedTo,
        uint256 indexed daiWithdrawn
    );
    event LogAdjustDeposit(
        address indexed user,
        uint256 indexed amount,
        bool increase
    );
    event LogHotPotatoPayment(address from, address to, uint256 amount);

    /*╔═════════════════════════════════╗
      ║           CONSTRUCTOR           ║
      ╚═════════════════════════════════╝*/

    constructor() {
        // initialise MetaTransactions
        _initializeEIP712("RealityCardsTreasury", "1");

        // at initiation, uberOwner and owner will be the same
        uberOwner = msg.sender;

        // initialise adjustable parameters
        setMinRental(24 * 6); // MinRental is a divisor of 1 day(86400 seconds), 24*6 will set to 10 minutes
        setMaxContractBalance(1000000 ether); // 1m
        setMaxBidLimit(30); // 30 is safe with current gas limit (12.5m)
    }

    /*╔═════════════════════════════════╗
      ║           MODIFIERS             ║
      ╚═════════════════════════════════╝*/

    /// @notice check that funds haven't gone missing during this function call
    modifier balancedBooks {
        _;
        // using >= not == because forced Ether send via selfdestruct will not trigger a deposit via the fallback
        require(
            address(this).balance >=
                totalDeposits + marketBalance + totalMarketPots,
            "books are unbalanced!"
        );
    }

    /// @notice only allow markets to call these functions
    modifier onlyMarkets {
        require(isMarket[msgSender()], "Not authorised");
        _;
    }

    /// @notice only allow orderbook to call these functions
    modifier onlyOrderbook {
        require(msgSender() == address(orderbook), "Not authorised");
        _;
    }

    /// @notice collect user rent before this function
    modifier rentCollect(address _user) {
        collectRentUser(_user);
        _;
    }

    // modifier collectRentUserAndSettleCard(uint256 card) {
    //     _collectRentUserAndSettleCard(card);
    //     _;
    // }

    /*╔═════════════════════════════════╗
      ║           ADD MARKETS           ║
      ╚═════════════════════════════════╝*/

    /// @dev so only markets can move funds from deposits to marketPots and vice versa
    function addMarket(address _newMarket) external override {
        require(msgSender() == factoryAddress, "Not factory");
        require(
            alternateReceiverBridgeAddress != address(0),
            "Alternate Receiver not set"
        );
        isMarket[_newMarket] = true;
    }

    /*╔═════════════════════════════════╗
      ║       GOVERNANCE - OWNER        ║
      ╚═════════════════════════════════╝*/

    /// @dev all functions should be onlyOwner
    // min rental event emitted by market. Nothing else need be emitted.

    /*┌────────────────────────────────────┐
      │ CALLED WITHIN CONSTRUTOR - PUBLIC  │
      └────────────────────────────────────┘*/

    /// @notice minimum rental duration (1 day divisor: i.e. 24 = 1 hour, 48 = 30 mins)
    function setMinRental(uint256 _newDivisor) public override onlyOwner {
        minRentalDayDivisor = _newDivisor;
    }

    /// @dev max deposit balance, to minimise funds at risk
    function setMaxContractBalance(uint256 _newBalanceLimit)
        public
        override
        onlyOwner
    {
        maxContractBalance = _newBalanceLimit;
    }

    /// @dev max bid limit, to fit within gas limits
    function setMaxBidLimit(uint256 _newBidLimit) public override onlyOwner {
        maxBidCountLimit = _newBidLimit;
    }

    /*┌──────────────────────────────────────────┐
      │ NOT CALLED WITHIN CONSTRUTOR - EXTERNAL  │
      └──────────────────────────────────────────┘*/

    /// @dev address of alternate receiver bridge, xdai side
    function setAlternateReceiverAddress(address _newAddress)
        external
        override
        onlyOwner
    {
        require(_newAddress != address(0), "Must set an address");
        alternateReceiverBridgeAddress = _newAddress;
    }

    /// @dev if true, cannot deposit, withdraw or rent any cards
    function changeGlobalPause() external override onlyOwner {
        globalPause = !globalPause;
    }

    /// @dev if true, cannot make a new rental for a specific market
    function changePauseMarket(address _market) external override onlyOwner {
        marketPaused[_market] = !marketPaused[_market];
    }

    /*╔═════════════════════════════════╗
      ║     GOVERNANCE - UBER OWNER     ║
      ╠═════════════════════════════════╣
      ║  ******** DANGER ZONE ********  ║
      ╚═════════════════════════════════╝*/
    /// @dev uber owner required for upgrades
    /// @dev deploying and setting a new factory is effectively an upgrade
    /// @dev this is seperated so owner so can be set to multisig, or burn address to relinquish upgrade ability
    /// @dev ... while maintaining governance over other governanace functions

    function setFactoryAddress(address _newFactory) external override {
        require(msgSender() == uberOwner, "Extremely Verboten");
        require(_newFactory != address(0));
        factoryAddress = _newFactory;
    }

    function setOrderbookAddress(address _newOrderbook) external {
        require(msgSender() == uberOwner, "Extremely Verboten");
        require(_newOrderbook != address(0));
        orderbook = IRCOrderbook(_newOrderbook);
    }

    function setNftHubAddress(address _NFTHubAddress) external {
        require(msgSender() == uberOwner, "Extremely Verboten");
        require(_NFTHubAddress != address(0));
        nfthub = IRCNftHubXdai(_NFTHubAddress);
    }

    function changeUberOwner(address _newUberOwner) external override {
        require(msgSender() == uberOwner, "Extremely Verboten");
        require(_newUberOwner != address(0));
        uberOwner = _newUberOwner;
    }

    /*╔═════════════════════════════════╗
      ║ DEPOSIT AND WITHDRAW FUNCTIONS  ║
      ╚═════════════════════════════════╝*/

    /// @dev it is passed the user instead of using msg.sender because might be called
    /// @dev ... via contract (fallback, newRental) or dai->xdai bot
    /// @param _user the user to credit the deposit to
    function deposit(address _user)
        public
        payable
        override
        balancedBooks
        returns (bool)
    {
        require(!globalPause, "Deposits are disabled");
        require(msg.value > 0, "Must deposit something");
        require(address(this).balance <= maxContractBalance, "Limit hit");
        require(_user != address(0), "Must set an address");

        user[_user].deposit += msg.value;
        totalDeposits += msg.value;
        emit LogDepositIncreased(_user, msg.value);
        emit LogAdjustDeposit(_user, msg.value, true);
        return true;
    }

    /// @notice withdraw a users deposit either directly or over the bridge to the mainnet
    /// @dev this is the only function where funds leave the contractthe
    /// @param _dai the amount to withdraw
    /// @param _localWithdrawal if true then withdraw to the users xDai address, otherwise to the mainnet
    function withdrawDeposit(uint256 _dai, bool _localWithdrawal)
        external
        override
        balancedBooks
    {
        require(!globalPause, "Withdrawals are disabled");
        address _msgSender = msgSender();
        require(user[_msgSender].deposit > 0, "Nothing to withdraw");
        require(
            block.timestamp - (user[_msgSender].lastRentalTime) >
                uint256(1 days) / minRentalDayDivisor,
            "Too soon"
        );

        // stpe 1: collect rent on owned cards
        orderbook.collectRentOwnedCards(_msgSender);

        // step 2: process withdrawal
        if (_dai > user[_msgSender].deposit) {
            _dai = user[_msgSender].deposit;
        }
        emit LogDepositWithdrawal(_msgSender, _dai);
        emit LogAdjustDeposit(_msgSender, _dai, false);
        user[_msgSender].deposit -= _dai;
        totalDeposits -= _dai;
        if (_localWithdrawal) {
            (bool _success, ) = payable(_msgSender).call{value: _dai}("");
            require(_success, "Transfer failed");
        } else {
            IAlternateReceiverBridge _alternateReceiverBridge =
                IAlternateReceiverBridge(alternateReceiverBridgeAddress);
            _alternateReceiverBridge.relayTokens{value: _dai}(
                address(this),
                _msgSender,
                _dai
            );
        }

        // step 3: remove bids if insufficient deposit
        if (
            user[_msgSender].bidRate != 0 &&
            user[_msgSender].bidRate / (minRentalDayDivisor) >
            user[_msgSender].deposit
        ) {
            orderbook.removeUserFromOrderbook(_msgSender);
        }
    }

    /*╔═════════════════════════════════╗
      ║        MARKET CALLABLE          ║
      ╚═════════════════════════════════╝*/
    // only markets can call these functions

    /// @notice a rental payment is equivalent to moving from user's deposit to market pot,
    /// @notice ..called by _collectRent in the market
    /// @param _dai amount of rent to pay in wei
    function payRent(uint256 _dai)
        external
        override
        balancedBooks
        onlyMarkets
        returns (bool)
    {
        require(!globalPause, "Rentals are disabled");
        address _market = msgSender();
        console.log("amount to collect", _dai);
        console.log("market balance ", marketBalance);
        //assert(marketBalance >= _dai);
        _decreaseMarketBalance(IRCMarket(_market), _dai);
        marketPot[_market] += _dai;
        totalMarketPots += _dai;

        return true;

        /// @dev the following now need to be done on user rent collection
        // user[_user].deposit = user[_user].deposit - _dai;
        // totalDeposits -= _dai;
        // emit LogAdjustDeposit(_user, _dai, false);
    }

    /// @notice a payout is equivalent to moving from market pot to user's deposit (the opposite of payRent)
    /// @param _user the user to query
    /// @param _dai amount to payout in wei
    function payout(address _user, uint256 _dai)
        external
        override
        balancedBooks
        onlyMarkets
        returns (bool)
    {
        require(!globalPause, "Payouts are disabled");
        assert(marketPot[msgSender()] >= _dai);
        user[_user].deposit += _dai;
        marketPot[msgSender()] -= _dai;
        totalMarketPots -= _dai;
        totalDeposits += _dai;
        emit LogAdjustDeposit(_user, _dai, true);
        return true;
    }

    /// @notice ability to add liqudity to the pot without being able to win (called by market sponsor function).
    function sponsor()
        external
        payable
        override
        balancedBooks
        onlyMarkets
        returns (bool)
    {
        require(!globalPause, "Global Pause is Enabled");
        marketPot[msgSender()] = marketPot[msgSender()] + (msg.value);
        totalMarketPots = totalMarketPots + (msg.value);
        return true;
    }

    /// @dev new owner pays current owner for hot potato mode
    function processHarbergerPayment(
        address _newOwner,
        address _currentOwner,
        uint256 _requiredPayment
    ) external override balancedBooks onlyMarkets returns (bool) {
        require(!globalPause, "Global Pause is Enabled");
        require(
            user[_newOwner].deposit >= _requiredPayment,
            "Insufficient deposit"
        );
        user[_newOwner].deposit = user[_newOwner].deposit - (_requiredPayment);
        user[_currentOwner].deposit =
            user[_currentOwner].deposit +
            (_requiredPayment);
        emit LogAdjustDeposit(_newOwner, _requiredPayment, false);
        emit LogAdjustDeposit(_currentOwner, _requiredPayment, true);
        emit LogHotPotatoPayment(_newOwner, _currentOwner, _requiredPayment);
        return true;
    }

    /// @notice tracks when the user last rented- so they cannot rent and immediately withdraw,
    /// @notice ..thus bypassing minimum rental duration
    /// @param _user the user to query
    function updateLastRentalTime(address _user)
        external
        override
        onlyMarkets
        returns (bool)
    {
        user[_user].lastRentalTime = block.timestamp;
        if (user[_user].lastRentCalc == 0) {
            user[_user].lastRentCalc = block.timestamp;
        }
        return true;
    }

    /// @notice adds or removes a market to the active markets array
    /// @param _open true if the market is open
    /// @dev this appears to be unused
    function updateMarketStatus(bool _open) external override onlyMarkets {
        if (_open) {
            isMarketActive[msgSender()] = true;
        } else {
            isMarketActive[msgSender()] = false;
        }
    }

    /*╔═════════════════════════════════╗
      ║        MARKET HELPERS           ║
      ╚═════════════════════════════════╝*/

    /// @notice provides the sum total of a users bids accross all markets
    /// @param _user the user address to query
    function userTotalBids(address _user)
        external
        view
        override
        returns (uint256)
    {
        return user[_user].bidRate;
    }

    /// @notice provide the users remaining deposit
    /// @param _user the user address to query
    function userDeposit(address _user)
        external
        view
        override
        returns (uint256)
    {
        return user[_user].deposit;
    }

    /*╔═════════════════════════════════╗
      ║      ORDERBOOK CALLABLE         ║
      ╚═════════════════════════════════╝*/

    /// @notice updates users rental rates when ownership changes
    /// @param _oldOwner the address of the user losing ownership
    /// @param _newOwner the address of the user gaining ownership
    /// @param _oldPrice the price the old owner was paying
    /// @param _newPrice the price the new owner will be paying
    function updateRentalRate(
        address _oldOwner,
        address _newOwner,
        uint256 _oldPrice,
        uint256 _newPrice,
        uint256 _timeOwnershipChanged
    ) external override onlyOrderbook {
        if (user[_newOwner].rentalRate != 0) {
            collectRentUser(_newOwner);
        } else {
            user[_newOwner].lastRentCalc = _timeOwnershipChanged;
        }
        // Must add before subtract, to avoid underflow in the case a user is only updating their price.
        user[_newOwner].rentalRate += (_newPrice);
        user[_oldOwner].rentalRate -= (_oldPrice);
    }

    function increaseBidRate(address _user, uint256 _price)
        external
        override
        onlyOrderbook
    {
        user[_user].bidRate += _price;
    }

    function decreaseBidRate(address _user, uint256 _price)
        external
        override
        onlyOrderbook
    {
        user[_user].bidRate -= _price;
    }

    /*╔═════════════════════════════════╗
      ║      RENT CALC HELPERS          ║
      ╚═════════════════════════════════╝*/

    /// @notice returns the rent due between the users last rent calcualtion and
    /// @notice ..the current block.timestamp for all cards a user owns
    /// @param _user the user to query
    /// @dev TODO consider making this internal
    function rentOwedUser(address _user) public view returns (uint256 rentDue) {
        return
            (user[_user].rentalRate *
                (block.timestamp - user[_user].lastRentCalc)) / (1 days);
    }

    /// @notice returns the amount of deposit a user is able to withdraw
    /// @notice ..after considering rent due to be paid
    /// @param _user the user to query
    /// @dev TODO consider making this internal
    function depositAbleToWithdraw(address _user)
        public
        view
        returns (uint256)
    {
        uint256 collection = rentOwedUser(_user);
        if (collection >= user[_user].deposit) {
            return 0;
        } else {
            return user[_user].deposit - (collection);
        }
    }

    /// @notice returns the current estimate of the users foreclosure time
    /// @param _user the user to query
    function foreclosureTimeUser(address _user)
        external
        view
        override
        returns (uint256)
    {
        uint256 totalUserDailyRent = user[_user].rentalRate;
        if (totalUserDailyRent > 0) {
            // timeLeftOfDeposit = deposit / (totalUserDailyRent / 1 day)
            //                   = (deposit * 1day) / totalUserDailyRent
            uint256 timeLeftOfDeposit =
                ((depositAbleToWithdraw(_user) * 1 days) +
                    // Add this to make sure this is the value rounded up
                    (totalUserDailyRent - 1)) / totalUserDailyRent;

            return block.timestamp + timeLeftOfDeposit;
        } else {
            // return 0;
            return type(uint256).max; // for testing, the orderbook assumes 0 means user already foreclosed
        }
    }

    /// @notice call for a rent collection on the given user
    /// @notice IF the user doesn't have enough deposit, returns foreclosure time
    /// @notice ..otherwise returns zero
    /// @param _user the user to query
    function collectRentUser(address _user)
        public
        override
        returns (uint256 newTimeLastCollectedOnForeclosure)
    {
        if (user[_user].lastRentCalc < block.timestamp) {
            console.log(" user collect rent on ", _user);
            uint256 rentOwedByUser = rentOwedUser(_user);

            if (rentOwedByUser > 0 && rentOwedByUser > user[_user].deposit) {
                // The User has run out of deposit already.
                uint256 previousCollectionTime = user[_user].lastRentCalc;

                /*
            timeTheirDepsitLasted = timeSinceLastUpdate * (usersDeposit/rentOwed)
                                  = (now - previousCollectionTime) * (usersDeposit/rentOwed)
            */
                uint256 timeUsersDepositLasts =
                    ((block.timestamp - previousCollectionTime) *
                        user[_user].deposit) / rentOwedByUser;
                /*
            Users last collection time = previousCollectionTime + timeTheirDepsitLasted
            */
                rentOwedByUser = user[_user].deposit;
                newTimeLastCollectedOnForeclosure =
                    previousCollectionTime +
                    timeUsersDepositLasts;
                _increaseMarketBalance(
                    IRCMarket(address(0)),
                    rentOwedByUser,
                    _user
                );
                user[_user].lastRentCalc = newTimeLastCollectedOnForeclosure;
                assert(user[_user].deposit == 0);
            } else {
                // User has enough deposit to pay rent.
                _increaseMarketBalance(
                    IRCMarket(address(0)),
                    rentOwedByUser,
                    _user
                );
                user[_user].lastRentCalc = block.timestamp;
            }
            emit LogAdjustDeposit(_user, rentOwedByUser, false);
        }
    }

    /// moving from the markets availiable balance to the market pot (market pot currently increased elsewhere)
    function _decreaseMarketBalance(IRCMarket market, uint256 rentCollected)
        internal
    {
        marketBalance -= rentCollected;
        market;
    }

    /// moving from the user deposit to the markets availiable balance
    function _increaseMarketBalance(
        IRCMarket market,
        uint256 rentCollected,
        address _user
    ) internal {
        marketBalance += rentCollected;
        user[_user].deposit -= rentCollected;
        totalDeposits -= rentCollected;
        market;
        // JS/TODO: implement this function
    }

    // JS/TODO: Add a concept of depth (currently only 1 user deep). Only update the current user, or loop through and update many users (in the case that card forecloses)
    function collectRentUserAndSettleCard(uint256 card)
        public
        override
        returns (bool didTokenForeclose)
    {
        address cardOwner = nfthub.ownerOf(card);
        uint256 newTimeLastCollectedOnForeclosure = collectRentUser(cardOwner);

        IRCMarket market = IRCMarket(nfthub.marketTracker(card));

        if (cardOwner != address(market)) {
            didTokenForeclose = newTimeLastCollectedOnForeclosure > 0;

            if (didTokenForeclose) {
                // JS/TODO: handle case of transferring card to next eligible user in order-book
                //  if eligible newOwner exists {
                //    set time token last rent collect to 'newTimeLastCollectedOnForeclosure'
                //  else {
                //    set time token last rent collect to 'now'
                //  }

                console.log(" USER FORECLOSED! PANIC!");
            } else {
                uint256 cardRentalRate = market.getTokenPrice(card);
                uint256 cardTimeLastCollected =
                    market.getTimeLastCollected(card);
                uint256 rentDueForCard =
                    (cardRentalRate *
                        (block.timestamp - cardTimeLastCollected)) / 1 days;

                if (rentDueForCard > 0) {
                    _increaseMarketBalance(market, rentDueForCard, cardOwner);
                }

                // the market collectRent will do this
                // market.updateCard(
                //     card,
                //     cardOwner,
                //     rentDueForCard,
                //     block.timestamp
                // );
            }
        }
    }

    /*╔═════════════════════════════════╗
      ║            FALLBACK             ║
      ╚═════════════════════════════════╝*/

    /// @dev sending ether/xdai direct is equal to a deposit
    receive() external payable {
        require(deposit(msgSender()));
    }
}
