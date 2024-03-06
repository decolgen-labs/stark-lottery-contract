#[starknet::contract]
mod Governance {
    use openzeppelin::access::ownable::interface::IOwnable;
    use core::option::OptionTrait;
    use alexandria_storage::list::ListTrait;
    use core::zeroable::Zeroable;
    use core::starknet::event::EventEmitter;
    use starknet::ContractAddress;
    use lottery::governance::interface::IGovernance;
    use openzeppelin::access::ownable::OwnableComponent;
    use alexandria_storage::list::List;

    // Implement Ownable component
    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    #[abi(embed_v0)]
    impl OwnableCamelOnlyImpl =
        OwnableComponent::OwnableCamelOnlyImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    const FEE_PRECISION: u128 = 1_000_000;
    const MIN_DURATION: u64 = 3600; // 60min

    // ------------------- Storage -------------------
    #[storage]
    struct Storage {
        randomness: ContractAddress,
        // protocol fee (20000 = 2%)
        protocolFee: u128,
        // mapping lottery address => lottery detail
        lotteries: LegacyMap::<ContractAddress, Lottery>,
        // list of active lotteries
        activeLotteries: List<ContractAddress>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    // -------------------- Event --------------------
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event
    }

    // -------------------- Struct --------------------
    #[derive(Drop, Copy, starknet::Store)]
    struct Lottery {
        isActive: bool, // True if the lottery if active
        minimumPrice: u256, // Minimum price of the lottery ticket with minimum selected numbers
        initialJackpot: u256, // Starting jackpot amount
        firstDrawTime: u64, // Time of the first lottery draw
        duration: u64, // Lottery duration
        index: u32
    }

    // ----------------- Constructor -----------------
    #[constructor]
    fn constructor(ref self: ContractState, admin: ContractAddress) {
        self.ownable.initializer(admin);
    }

    #[abi(embed_v0)]
    impl GovernanceImpl of IGovernance<ContractState> {
        fn changeAdmin(ref self: ContractState, newAdmin: ContractAddress) {
            self.ownable.assert_only_owner();
            self.ownable.initializer(newAdmin);
        }

        fn changeRandomness(ref self: ContractState, newRandom: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(newRandom.is_non_zero(), 'Require non-zero address');
            self.randomness.write(newRandom);
        }

        fn changeFee(ref self: ContractState, newFee: u128) {
            self.ownable.assert_only_owner();
            assert(newFee > 0 && newFee != self.protocolFee.read(), 'Wrong new fee');
            self.protocolFee.write(newFee);
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

        fn changeDuration(ref self: ContractState, lottery: ContractAddress, newDuration: u64) {
            self.ownable.assert_only_owner();
            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(
                newDuration >= MIN_DURATION && newDuration != lotteryDetail.duration,
                'Wrong duration'
            );

            lotteryDetail.duration = newDuration;
            self.lotteries.write(lottery, lotteryDetail);
        }

        fn createLottery(
            ref self: ContractState,
            lottery: ContractAddress,
            minimumPrice: u256,
            duration: u64,
            initialJackpot: u256,
            firstDrawTime: u64
        ) {
            self.ownable.assert_only_owner();
            assert(lottery.is_non_zero(), 'Require non-zero lottery');
            assert(minimumPrice > 0, 'Wrong minimum price');
            assert(duration >= MIN_DURATION, 'Wrong duration');

            let mut lotteryDetail: Lottery = self.lotteries.read(lottery);
            assert(!lotteryDetail.isActive, 'Lottery already active');

            let mut activeLotteries = self.activeLotteries.read();
            let index = activeLotteries.len();
            activeLotteries.append(lottery);

            lotteryDetail.isActive = true;
            lotteryDetail.minimumPrice = minimumPrice;
            lotteryDetail.duration = duration;
            lotteryDetail.firstDrawTime = firstDrawTime;
            lotteryDetail.initialJackpot = initialJackpot;
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

        fn getAdmin(self: @ContractState) -> ContractAddress {
            self.ownable.owner()
        }

        fn validateLottery(self: @ContractState, lottery: ContractAddress) -> bool {
            self.getLottery(lottery).isActive
        }

        fn getMinimumPrice(self: @ContractState, lottery: ContractAddress) -> u256 {
            self.getLottery(lottery).minimumPrice
        }

        fn getDuration(self: @ContractState, lottery: ContractAddress) -> u64 {
            self.getLottery(lottery).duration
        }

        fn getInitialJackpot(self: @ContractState, lottery: ContractAddress) -> u256 {
            self.getLottery(lottery).initialJackpot
        }

        fn getFirstDrawtime(self: @ContractState, lottery: ContractAddress) -> u64 {
            self.getLottery(lottery).firstDrawTime
        }

        fn getActiveLotteries(self: @ContractState) -> Array::<ContractAddress> {
            self.activeLotteries.read().array()
        }
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn getLottery(self: @ContractState, lottery: ContractAddress) -> Lottery {
            self.lotteries.read(lottery)
        }
    }
}
