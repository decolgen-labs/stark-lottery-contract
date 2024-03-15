#[starknet::contract]
mod Lottery645 {
    use core::array::{ArrayTrait, Array};
    use alexandria_storage::list::ListTrait;
    use lottery::ticket::interface::ITicketDispatcherTrait;
    use lottery::governance::interface::{IGovernanceDispatcher, IGovernanceDispatcherTrait};
    use lottery::lottery::interface::{LotteryDetail, ILottery, LotteryGetterStruct};
    use lottery::ticket::interface::{ITicketDispatcher, TicketHash};
    use lottery::randomness::interface::{IRandomnessDispatcher, IRandomnessDispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::security::reentrancyguard::ReentrancyGuardComponent;
    use starknet::{
        ContractAddress, get_contract_address, get_block_timestamp, get_caller_address, get_tx_info
    };
    use integer::{BoundedU64, BoundedU32};
    use pedersen::{PedersenTrait, HashState};
    use hash::{HashStateTrait, HashStateExTrait};

    const MUST_PICK_NUMBERS: u8 = 6;

    const MAX_NUMBER: u32 = 45;

    const U256_TYPE_HASH: felt252 = selector!("u256(low:felt,high:felt)");


    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: ReentrancyGuardComponent, storage: reentrancy, event: ReentrancyEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    impl ReentrancyInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    // ------------------- Storage -------------------
    #[storage]
    struct Storage {
        governanceContract: IGovernanceDispatcher,
        // current lottery id
        lotteryId: u128,
        // mapping lottery id => detail
        lotteries: LegacyMap::<u128, LotteryDetail>,
        // mapping (lottery id , number) => true if is was drawn
        isDrawnNumber: LegacyMap::<(u128, u32), bool>,
        prizeMultipliers: LegacyMap::<u8, u16>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        reentrancy: ReentrancyGuardComponent::Storage,
    }

    // ------------------- Constructor -------------------
    #[constructor]
    fn constructor(
        ref self: ContractState, owner: ContractAddress, governanceAddress: ContractAddress
    ) {
        self.ownable.initializer(owner);
        self
            .governanceContract
            .write(IGovernanceDispatcher { contract_address: governanceAddress });
        self.prizeMultipliers.write(2, 1);
        self.prizeMultipliers.write(3, 3);
        self.prizeMultipliers.write(4, 30);
        self.prizeMultipliers.write(5, 2000);
    }

    // --------------------- Event ---------------------
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        StartNewLottery: StartNewLottery,
        DrawnNumbers: DrawnNumbers,
        WithdrawWinning: WithdrawWinning,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        ReentrancyEvent: ReentrancyGuardComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct DrawnNumbers {
        #[key]
        lotteryId: u128,
        drawnNumbers: Span::<u32>
    }

    #[derive(Drop, starknet::Event)]
    struct StartNewLottery {
        #[key]
        id: u128,
        drawTime: u64,
        jackpot: u256
    }

    #[derive(Drop, starknet::Event)]
    struct WithdrawWinning {
        #[key]
        userAddress: ContractAddress,
        lottery: ContractAddress,
        lotteryId: u128,
        ticketId: u128,
        payout: u256
    }

    #[derive(Drop, Copy)]
    struct RandomParam {
        randomWord: @felt252,
        totalValue: u256,
        secondArg: u128
    }

    #[abi(embed_v0)]
    impl LotteryImpl of ILottery<ContractState> {
        fn startNewLottery(ref self: ContractState) {
            self.ownable.assert_only_owner();
            let governance = self.governanceContract.read();
            let thisLottery = get_contract_address();
            assert(governance.validateLottery(thisLottery), 'Invalid Lottery');
            let currentDrawId = self.lotteryId.read();
            let mut timeOfNextDraw: u64 = 0;
            let mut initJackpot = governance.getInitialJackpot(thisLottery);

            // check if current lottery id is not the first
            if currentDrawId != 0 {
                let currentLottery = self.lotteries.read(currentDrawId);
                assert(currentLottery.state == 0, 'Current lottery must be closed');

                let presetDuration = governance.getDuration(thisLottery);
                timeOfNextDraw = currentLottery.drawTime + presetDuration;
                loop {
                    if get_block_timestamp() < timeOfNextDraw {
                        break;
                    }

                    timeOfNextDraw += presetDuration;
                };

                // compute the jackpot for next draw
                let winnerTicketHash = TicketHash {
                    lotteryAddress: thisLottery,
                    lotteryId: currentDrawId,
                    pickedNumbers: currentLottery.drawnNumbers.array().span()
                };
                let isHasWinner = ITicketDispatcher {
                    contract_address: governance.getTicketContract()
                }
                    .getCombinationCounter(winnerTicketHash) > 0;

                if !isHasWinner {
                    let preTotalValue = currentLottery.totalValue;
                    initJackpot += governance.computeGrowingJackPot(thisLottery, preTotalValue);
                }
            } else {
                timeOfNextDraw = governance.getFirstDrawtime(thisLottery);
            }

            let newDrawId = currentDrawId + 1;
            let mut newDrawDetail = self.lotteries.read(newDrawId);
            newDrawDetail.lotteryId = newDrawId;
            newDrawDetail.minimumPrice = governance.getMinimumPrice(thisLottery);
            newDrawDetail.state = 1;
            newDrawDetail.drawTime = timeOfNextDraw;
            newDrawDetail.totalValue = 0;
            newDrawDetail.jackpot = initJackpot;
            self.lotteries.write(newDrawId, newDrawDetail);
            self.lotteryId.write(newDrawId);
            self
                .emit(
                    StartNewLottery {
                        id: newDrawId, drawTime: timeOfNextDraw, jackpot: initJackpot
                    }
                )
        }

        fn buyTicket(ref self: ContractState, pickedNumbers: Span::<u32>) {
            self.reentrancy.start();
            let currentLotteryId = self.lotteryId.read();
            let mut lotteryDetail = self.lotteries.read(currentLotteryId);

            assert(lotteryDetail.state == 1, 'Ticket sale not open');
            assert(get_block_timestamp() < lotteryDetail.drawTime - 300, 'Ticket sale is closed');
            assert(pickedNumbers.len() == MUST_PICK_NUMBERS.into(), 'Wrong picked numbers');

            let ticketPrice = lotteryDetail.minimumPrice;

            // check unique and numbers is in range 1 - MAXNUMBER
            let mut index: u32 = 0;
            let mut arrayPickedNumbers = ArrayTrait::<u32>::new();
            arrayPickedNumbers = loop {
                if index == MUST_PICK_NUMBERS.into() {
                    break arrayPickedNumbers.clone();
                }

                let pickedNumer = *pickedNumbers.at(index);
                assert(pickedNumer >= 1 && pickedNumer <= MAX_NUMBER, 'Wrong picked number');
                if index > 0 {
                    let preNumber = *pickedNumbers.at(index - 1);
                    assert(preNumber < pickedNumer, 'Only sorted and unique numbers');
                }

                arrayPickedNumbers.append(pickedNumer);
                index += 1;
            };

            let buyer = get_caller_address();
            let governance = self.governanceContract.read();
            governance.payTicketPrice(buyer);

            let newTicket = ITicketDispatcher { contract_address: governance.getTicketContract() }
                .createTicket(arrayPickedNumbers, currentLotteryId, buyer);

            lotteryDetail.totalValue += ticketPrice;
            self.lotteries.write(currentLotteryId, lotteryDetail);
            self.reentrancy.end();
        }

        fn startDrawing(ref self: ContractState) {
            self.ownable.assert_only_owner();
            let currentLotteryId = self.lotteryId.read();
            let mut lotteryDetail = self.lotteries.read(currentLotteryId);
            let drawTime = lotteryDetail.drawTime;

            assert(get_block_timestamp() >= drawTime, 'Not yet to draw');
            let totalValue = lotteryDetail.totalValue;

            let governance = self.governanceContract.read();
            let thisLottery = get_contract_address();

            if totalValue > 0 {
                let mut newLotteryState = self.lotteries.read(currentLotteryId);
                newLotteryState.state = 2;
                self.lotteries.write(currentLotteryId, newLotteryState);
                IRandomnessDispatcher { contract_address: governance.getRandomnessContract() }
                    .getRandom(get_tx_info().unbox().signature)
            } else {
                let presetDuration = governance.getDuration(thisLottery);
                let mut timeOfNextDraw = drawTime + presetDuration;
                loop {
                    if get_block_timestamp() < timeOfNextDraw {
                        break;
                    }

                    timeOfNextDraw += presetDuration;
                };

                let mut newLottery = self.lotteries.read(currentLotteryId);
                newLottery.drawTime = timeOfNextDraw;
                self.lotteries.write(currentLotteryId, newLottery);

                self
                    .emit(
                        StartNewLottery {
                            id: currentLotteryId,
                            drawTime: timeOfNextDraw,
                            jackpot: lotteryDetail.jackpot
                        }
                    );
            }
        }

        fn fulfillDrawing(ref self: ContractState, randomWord: felt252) {
            let caller = get_caller_address();
            let mut governance = self.governanceContract.read();
            assert(caller == governance.getRandomnessContract(), 'Only Randomness Contract');

            let currentLotteryId = self.lotteryId.read();
            let mut lotteryDetail = self.lotteries.read(currentLotteryId);
            let totalValue = lotteryDetail.totalValue;

            let mut drawCount: u8 = 0;
            let mut secondArg: u128 = 0;
            let mut newDrawnNumers = ArrayTrait::<u32>::new();

            let result = loop {
                if drawCount == MUST_PICK_NUMBERS {
                    break newDrawnNumers.clone();
                }

                let mut isUnique = true;
                let randomWordParam = RandomParam {
                    randomWord: @randomWord, totalValue, secondArg
                };
                let drawNumber = (randomWordParam.convertToU32() % MAX_NUMBER) + 1;

                if drawCount > 0 {
                    let mut cpDrawnNumers = newDrawnNumers.clone();
                    let mut index: u32 = 0;
                    isUnique =
                        loop {
                            if index == drawCount.into() {
                                break isUnique;
                            }

                            if drawNumber == *cpDrawnNumers.at(index) {
                                isUnique = false;
                                break isUnique;
                            }

                            index += 1;
                        };
                }

                if isUnique {
                    self.isDrawnNumber.write((currentLotteryId, drawNumber), true);
                    newDrawnNumers.append(drawNumber);
                    drawCount += 1;
                };

                secondArg += 1;
            };

            lotteryDetail.state = 0;
            lotteryDetail.drawnNumbers.from_array(@result);
            self.lotteries.write(currentLotteryId, lotteryDetail);

            self.emit(DrawnNumbers { lotteryId: currentLotteryId, drawnNumbers: result.span() });

            self.startNewLottery();
        }


        fn claimRewards(ref self: ContractState, ticketId: u128) {
            self.reentrancy.start();
            let governance = self.governanceContract.read();
            let ticketDispatcher = ITicketDispatcher {
                contract_address: governance.getTicketContract()
            };

            let ticketDetail = ticketDispatcher.getTicketById(ticketId);
            let caller = get_caller_address();
            let lottery = get_contract_address();
            assert(caller == ticketDetail.user, 'Invalid ticket');
            assert(ticketDetail.lotteryAddress == lottery, 'Wrong Lottery');
            assert(ticketDetail.payOut == 0, 'Ticket already claimed');

            let pickedNumbers = ticketDetail.pickedNumbers.span();
            let lotteryId = ticketDetail.lotteryId;
            let lotteryDetail = self.lotteries.read(lotteryId);
            let mut index: u32 = 0;
            let mut couter = 0;

            let matchedCounter: u8 = loop {
                if index == MUST_PICK_NUMBERS.into() {
                    break couter;
                }

                let number = pickedNumbers.at(index);
                if self.isDrawnNumber.read((lotteryId, *number)) {
                    couter += 1
                }
                index += 1;
            };

            assert(matchedCounter >= 2, 'Ticket lost');

            let mut payout: u256 = 0;
            if matchedCounter >= 2 && matchedCounter <= 5 {
                payout = self.prizeMultipliers.read(matchedCounter).into()
                    * self.lotteries.read(lotteryId).minimumPrice;
            } else if matchedCounter == MUST_PICK_NUMBERS {
                assert(ticketDetail.sameCombinationCounter > 0, 'Wrong Ticket');
                payout == lotteryDetail.jackpot / ticketDetail.sameCombinationCounter.into();
            }

            assert(payout > 0, 'Wrong payout amount');
            ticketDispatcher.setPaidOut(ticketId, payout);
            governance.payoutWinner(caller, payout);

            self
                .emit(
                    WithdrawWinning { userAddress: caller, lottery, lotteryId, ticketId, payout }
                );

            self.reentrancy.end();
        }

        fn getCurrentLottery(self: @ContractState) -> LotteryGetterStruct {
            let currentLotteryId = self.lotteryId.read();
            if currentLotteryId == 0 {
                return LotteryGetterStruct {
                    id: 0,
                    minimumPrice: 0,
                    state: 0,
                    drawTime: 0,
                    drawnNumbers: array![].span(),
                    amountOfTickets: 0,
                    totalValue: 0,
                    jackpot: 0,
                    jackpotWinners: 0
                };
            }

            let lotteryDetail = self.lotteries.read(currentLotteryId);

            let governance = self.governanceContract.read();
            let drawnNumbers = lotteryDetail.drawnNumbers.array().span();

            let amountOfTickets: u128 = (lotteryDetail.totalValue / lotteryDetail.minimumPrice)
                .try_into()
                .unwrap();

            let mut jackpotWinners = 0;
            if drawnNumbers.len() > 0 {
                jackpotWinners =
                    ITicketDispatcher { contract_address: governance.getTicketContract() }
                    .getCombinationCounter(
                        TicketHash {
                            lotteryAddress: get_contract_address(),
                            lotteryId: currentLotteryId,
                            pickedNumbers: drawnNumbers
                        }
                    );
            }

            let lotteryGetterStruct = LotteryGetterStruct {
                id: lotteryDetail.lotteryId,
                minimumPrice: lotteryDetail.minimumPrice,
                state: lotteryDetail.state,
                drawTime: lotteryDetail.drawTime,
                drawnNumbers: drawnNumbers,
                amountOfTickets: amountOfTickets,
                totalValue: lotteryDetail.totalValue,
                jackpot: lotteryDetail.jackpot,
                jackpotWinners
            };

            lotteryGetterStruct
        }

        fn getLotteryById(self: @ContractState, lotteryId: u128) -> LotteryGetterStruct {
            let lotteryDetail = self.lotteries.read(lotteryId);

            if lotteryDetail.drawTime == 0 {
                return LotteryGetterStruct {
                    id: 0,
                    minimumPrice: 0,
                    state: 0,
                    drawTime: 0,
                    drawnNumbers: array![].span(),
                    amountOfTickets: 0,
                    totalValue: 0,
                    jackpot: 0,
                    jackpotWinners: 0
                };
            }

            let governance = self.governanceContract.read();
            let drawnNumbers = lotteryDetail.drawnNumbers.array().span();

            let amountOfTickets: u128 = (lotteryDetail.totalValue / lotteryDetail.minimumPrice)
                .try_into()
                .unwrap();

            let mut jackpotWinners = 0;
            if drawnNumbers.len() > 0 {
                jackpotWinners =
                    ITicketDispatcher { contract_address: governance.getTicketContract() }
                    .getCombinationCounter(
                        TicketHash {
                            lotteryAddress: get_contract_address(),
                            lotteryId,
                            pickedNumbers: drawnNumbers
                        }
                    );
            }
            let lotteryGetterStruct = LotteryGetterStruct {
                id: lotteryDetail.lotteryId,
                minimumPrice: lotteryDetail.minimumPrice,
                state: lotteryDetail.state,
                drawTime: lotteryDetail.drawTime,
                drawnNumbers: drawnNumbers,
                amountOfTickets: amountOfTickets,
                totalValue: lotteryDetail.totalValue,
                jackpot: lotteryDetail.jackpot,
                jackpotWinners,
            };

            lotteryGetterStruct
        }

        fn getLotteryByIds(
            self: @ContractState, lotteryIds: Span::<u128>
        ) -> Span::<LotteryGetterStruct> {
            let mut lotteries = ArrayTrait::<LotteryGetterStruct>::new();
            let idsLength = lotteryIds.len();

            let mut index: u32 = 0;
            loop {
                if index == idsLength {
                    break lotteries.span();
                }

                let lotteryId = lotteryIds.at(index);
                lotteries.append(self.getLotteryById(*lotteryId));
                index += 1;
            }
        }
    }

    #[abi(per_item)]
    #[generate_trait]
    impl Internal of InternalTrait {
        #[external(v0)]
        fn testGetRandomNumbers(
            self: @ContractState, randomWord: felt252, totalValue: u256
        ) -> Array::<u32> {
            let mut drawCount: u8 = 0;
            let mut secondArg: u128 = 0;
            let mut newDrawnNumers = ArrayTrait::<u32>::new();

            let result = loop {
                if drawCount == MUST_PICK_NUMBERS {
                    break newDrawnNumers.clone();
                }

                let mut isUnique = true;
                let randomWordParam = RandomParam {
                    randomWord: @randomWord, totalValue, secondArg
                };
                let drawNumber = (randomWordParam.convertToU32() % MAX_NUMBER) + 1;

                if drawCount > 0 {
                    let mut cpDrawnNumers = newDrawnNumers.clone();
                    let mut index: u32 = 0;
                    isUnique =
                        loop {
                            if index == drawCount.into() {
                                break isUnique;
                            }

                            if drawNumber == *cpDrawnNumers.at(index) {
                                isUnique = false;
                                break isUnique;
                            }

                            index += 1;
                        };
                }

                if isUnique {
                    newDrawnNumers.append(drawNumber);
                    drawCount += 1;
                };

                secondArg += 1;
            };

            result
        }
    }

    #[generate_trait]
    impl StructHashU256 of IStructHash {
        fn hashStruct(self: @u256) -> felt252 {
            let mut state = PedersenTrait::new(0);
            state = state.update_with(U256_TYPE_HASH);
            state = state.update_with(*self);
            state = state.update_with(3);
            state.finalize()
        }
    }

    #[generate_trait]
    impl StructRandomWord of StructRandomWordTrait {
        fn hashRandomWord(self: @RandomParam) -> felt252 {
            let block_timestamp = get_block_timestamp();
            let mut hash = PedersenTrait::new(0);
            hash.update_with(**self.randomWord);
            hash.update_with(block_timestamp);
            hash.update_with(self.totalValue.hashStruct());
            hash.update_with(*self.secondArg);
            hash.update_with(4);
            hash.finalize()
        }

        fn convertToU32(self: @RandomParam) -> u32 {
            let hash = self.hashRandomWord();
            let hash_u256: u256 = hash.into();
            let mut hash_u128 = hash_u256.low / BoundedU64::max().into();
            let hash_u64: u64 = loop {
                if hash_u128 <= BoundedU64::max().into() {
                    break hash_u128.try_into().unwrap();
                }

                hash_u128 - 1;
            };

            let hash_u32: u32 = loop {
                if hash_u64 <= BoundedU32::max().into() {
                    break hash_u64.try_into().unwrap();
                }

                hash_u64 - 1;
            };

            hash_u32
        }
    }
}
