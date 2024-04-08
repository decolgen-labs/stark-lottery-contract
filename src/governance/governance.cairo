#[starknet::contract]
mod Governance {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use lottery::governance::interface::IGovernance;
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use openzeppelin::token::erc20::interface::{IERC20CamelDispatcher, IERC20CamelDispatcherTrait};
    use alexandria_storage::list::{List, ListTrait};

    // Implement Ownable component
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    component!(path: ReentrancyGuardComponent, storage: reentrancy, event: ReentrancyEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    #[abi(embed_v0)]
    impl OwnableCamelOnlyImpl =
        OwnableComponent::OwnableCamelOnlyImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl ReentrancyInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    const FEE_PRECISION: u128 = 1_000_000;
    const MIN_DURATION: u64 = 3600; // 60min

    // ------------------- Storage -------------------
    #[storage]
    struct Storage {
        randomnessContract: ContractAddress,
        ticketContract: ContractAddress,
        // mapping lottery address => lottery detail
        lotteries: LegacyMap::<ContractAddress, Lottery>,
        // list of active lotteries
        activeLotteries: List<ContractAddress>,
        jackpotPool: u256,
        currency: ContractAddress,
        rewardPool: u256,
        feeRecipient: ContractAddress,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy: ReentrancyGuardComponent::Storage,
    }

    // -------------------- Event --------------------
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyEvent: ReentrancyGuardComponent::Event,
    }

    // -------------------- Struct --------------------
    #[derive(Drop, Copy, starknet::Store)]
    struct Lottery {
        isActive: bool, // True if the lottery if active
        minimumPrice: u256, // Minimum price of the lottery ticket with minimum selected numbers
        initialJackpot: u256, // Starting jackpot amount
        firstStartTime: u64, // Time of the first lottery draw
        durationStartTime: u64, // Lottery duration start time
        durationBuyTicket: u64, // Lottery duration buying ticket
        // The percentage based on the total value of tickets sold increase the jackpot 
        // after each game if no one wins
        increaseJackpot: u128,
        index: u32
    }

    // ----------------- Constructor -----------------
    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        currency: ContractAddress,
        feeRecipient: ContractAddress,
    ) {
        self.ownable.initializer(admin);
        self.currency.write(currency);
        self.feeRecipient.write(feeRecipient);
    }

    #[abi(embed_v0)]
    impl GovernanceImpl of IGovernance<ContractState> {
        fn changeAdmin(ref self: ContractState, newAdmin: ContractAddress) {
            self.ownable.assert_only_owner();
            self.ownable.initializer(newAdmin);
        }

        fn changeFeeRecipient(ref self: ContractState, newFeeRecipient: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(newFeeRecipient.is_non_zero(), 'Only Allow None Zero Address');
            self.feeRecipient.write(newFeeRecipient);
        }


        fn changeRandomness(ref self: ContractState, newRandom: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(newRandom.is_non_zero(), 'Require non-zero address');
            self.randomnessContract.write(newRandom);
        }

        fn changeTicket(ref self: ContractState, newTicketContract: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(newTicketContract.is_non_zero(), 'Require non-zero address');
            self.ticketContract.write(newTicketContract);
        }

        fn changeMinimumPrice(
            ref self: ContractState, lottery: ContractAddress, newMinPrice: u256
        ) {
            self.ownable.assert_only_owner();
            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(
                newMinPrice > 0 && newMinPrice != lotteryDetail.minimumPrice, 'Wrong minimun price'
            );

            lotteryDetail.minimumPrice = newMinPrice;
            self.lotteries.write(lottery, lotteryDetail);
        }

        fn changeInitialJackpot(
            ref self: ContractState, lottery: ContractAddress, newInitJackPot: u256
        ) {
            self.ownable.assert_only_owner();
            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(
                newInitJackPot > 0 && newInitJackPot != lotteryDetail.initialJackpot,
                'Wrong initial jackpot'
            );

            lotteryDetail.initialJackpot = newInitJackPot;
            self.lotteries.write(lottery, lotteryDetail);
        }

        fn changeDurationStartTime(
            ref self: ContractState, lottery: ContractAddress, newDuration: u64
        ) {
            self.ownable.assert_only_owner();
            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(newDuration != lotteryDetail.durationStartTime, 'Wrong duration');

            lotteryDetail.durationStartTime = newDuration;
            self.lotteries.write(lottery, lotteryDetail);
        }

        fn changeDurationBuyTicket(
            ref self: ContractState, lottery: ContractAddress, newDuration: u64
        ) {
            self.ownable.assert_only_owner();
            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(
                newDuration >= MIN_DURATION && newDuration != lotteryDetail.durationBuyTicket,
                'Wrong duration'
            );

            lotteryDetail.durationBuyTicket = newDuration;
            self.lotteries.write(lottery, lotteryDetail);
        }

        fn createLottery(
            ref self: ContractState,
            lottery: ContractAddress,
            minimumPrice: u256,
            durationStartTime: u64,
            durationBuyTicket: u64,
            initialJackpot: u256,
            increaseJackpot: u128,
            firstStartTime: u64,
        ) {
            self.ownable.assert_only_owner();
            assert(lottery.is_non_zero(), 'Require non-zero lottery');
            assert(minimumPrice > 0, 'Wrong minimum price');
            assert(durationStartTime >= MIN_DURATION, 'Wrong duration');
            assert(durationBuyTicket >= MIN_DURATION, 'Wrong duration');

            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(!lotteryDetail.isActive, 'Lottery already active');

            let mut activeLotteries = self.activeLotteries.read();
            let index = activeLotteries.len();
            activeLotteries.append(lottery);

            lotteryDetail.isActive = true;
            lotteryDetail.minimumPrice = minimumPrice;
            lotteryDetail.durationBuyTicket = durationBuyTicket;
            lotteryDetail.durationStartTime = durationStartTime;
            lotteryDetail.firstStartTime = firstStartTime;
            lotteryDetail.initialJackpot = initialJackpot;
            lotteryDetail.increaseJackpot = increaseJackpot;
            lotteryDetail.index = index;
            self.lotteries.write(lottery, lotteryDetail);
        }

        fn cancelLottery(ref self: ContractState, lottery: ContractAddress) {
            self.ownable.assert_only_owner();
            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(lotteryDetail.isActive, 'Lottery already inactive');

            lotteryDetail.isActive = false;
            let mut activeLotteries = self.activeLotteries.read();
            let index = lotteryDetail.index;
            let latestIndex = activeLotteries.len() - 1;

            if latestIndex != index {
                // move the canceled lottery into the last and vice versa
                let latestActiveLottery = activeLotteries.get(latestIndex).unwrap();
                let canceledLottery = activeLotteries.get(index).unwrap();
                activeLotteries.set(index, latestActiveLottery);
                activeLotteries.set(latestIndex, canceledLottery);

                let mut latestLotteryDetail: Lottery = self.lotteries.read(latestActiveLottery);
                latestLotteryDetail.index = index;
                self.lotteries.write(latestActiveLottery, latestLotteryDetail);
            }

            self.lotteries.write(lottery, lotteryDetail);
            activeLotteries.pop_front();
            self.activeLotteries.write(activeLotteries);
        }

        fn payTicketPrice(ref self: ContractState, buyer: ContractAddress) {
            let lottery = get_caller_address();
            assert(self.validateLottery(lottery), 'Caller must be lottery');

            let ticketPrice = self.getMinimumPrice(lottery);
            IERC20CamelDispatcher { contract_address: self.currency.read() }
                .transferFrom(buyer, self.feeRecipient.read(), ticketPrice);
        }

        fn payoutWinner(
            ref self: ContractState, winner: ContractAddress, amount: u256, isJackpotWinner: bool
        ) {
            self.reentrancy.start();
            let lottery = get_caller_address();
            assert(self.validateLottery(lottery), 'Caller must be lottery');

            if isJackpotWinner {
                assert(amount <= self.jackpotPool.read(), 'Insufficient jackpot pool');

                self.jackpotPool.write(self.jackpotPool.read() - amount);
                IERC20CamelDispatcher { contract_address: self.currency.read() }
                    .transfer(winner, amount);
            } else {
                assert(amount <= self.rewardPool.read(), 'Insufficient reward pool');

                self.rewardPool.write(self.rewardPool.read() - amount);
                IERC20CamelDispatcher { contract_address: self.currency.read() }
                    .transfer(winner, amount);
            }

            self.reentrancy.end();
        }


        fn computeGrowingJackPot(
            self: @ContractState, lottery: ContractAddress, totalValue: u256
        ) -> u256 {
            Div::div(
                Mul::mul(totalValue, self.lotteries.read(lottery).increaseJackpot.into()),
                FEE_PRECISION.into()
            )
        }

        fn getAdmin(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }

        fn getJackpotPool(self: @ContractState) -> u256 {
            self.jackpotPool.read()
        }

        fn getRandomnessContract(self: @ContractState) -> ContractAddress {
            self.randomnessContract.read()
        }
        fn getTicketContract(self: @ContractState) -> ContractAddress {
            self.ticketContract.read()
        }

        fn validateLottery(self: @ContractState, lottery: ContractAddress) -> bool {
            self.getLottery(lottery).isActive
        }

        fn getMinimumPrice(self: @ContractState, lottery: ContractAddress) -> u256 {
            self.getLottery(lottery).minimumPrice
        }

        fn getDurationStartTime(self: @ContractState, lottery: ContractAddress) -> u64 {
            self.getLottery(lottery).durationStartTime
        }

        fn getDurationBuyTicket(self: @ContractState, lottery: ContractAddress) -> u64 {
            self.getLottery(lottery).durationBuyTicket
        }

        fn getInitialJackpot(self: @ContractState, lottery: ContractAddress) -> u256 {
            self.getLottery(lottery).initialJackpot
        }

        fn getFirstStartTime(self: @ContractState, lottery: ContractAddress) -> u64 {
            self.getLottery(lottery).firstStartTime
        }

        fn getActiveLotteries(self: @ContractState) -> Span::<ContractAddress> {
            self.activeLotteries.read().array().span()
        }
    }

    #[abi(per_item)]
    #[generate_trait]
    impl AdditionalAccessors of AdditionalAccessorsTrait {
        #[external(v0)]
        fn getCurrency(self: @ContractState) -> ContractAddress {
            self.currency.read()
        }

        #[external(v0)]
        fn withdrawRewardPool(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();

            assert(amount <= self.rewardPool.read(), 'Insufficient Balance');

            self.rewardPool.write(self.rewardPool.read() - amount);
            IERC20CamelDispatcher { contract_address: self.currency.read() }
                .transfer(get_caller_address(), amount);
        }

        #[external(v0)]
        fn withdrawJackpotPool(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();

            assert(amount <= self.jackpotPool.read(), 'Insufficient Balance');

            self.jackpotPool.write(self.jackpotPool.read() - amount);
            IERC20CamelDispatcher { contract_address: self.currency.read() }
                .transfer(get_caller_address(), amount);
        }

        #[external(v0)]
        fn topupRewardPool(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();

            IERC20CamelDispatcher { contract_address: self.currency.read() }
                .transferFrom(get_caller_address(), get_contract_address(), amount);
            self.rewardPool.write(self.rewardPool.read() + amount);
        }

        #[external(v0)]
        fn topupJackpotPool(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();

            IERC20CamelDispatcher { contract_address: self.currency.read() }
                .transferFrom(get_caller_address(), get_contract_address(), amount);
            self.jackpotPool.write(self.jackpotPool.read() + amount);
        }

        #[external(v0)]
        fn updateCurrency(ref self: ContractState, currency: ContractAddress) {
            self.ownable.assert_only_owner();

            self.currency.write(currency);
        }
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn getLottery(self: @ContractState, lottery: ContractAddress) -> Lottery {
            self.lotteries.read(lottery)
        }
    }
}
