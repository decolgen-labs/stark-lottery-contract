#[starknet::contract]
mod Ticket {
    use lottery::governance::interface::IGovernanceDispatcherTrait;
    use lottery::ticket::interface::{ITicket, TicketHash, TicketGetter};
    use lottery::governance::interface::IGovernanceDispatcher;
    use openzeppelin::access::ownable::OwnableComponent;
    use starknet::ContractAddress;
    use array::{Array, Span, ArrayTrait};
    use starknet::{get_caller_address};
    use alexandria_storage::list::{List, ListTrait};
    use pedersen::{PedersenTrait, HashState};
    use poseidon::poseidon_hash_span;
    use hash::{HashStateTrait, HashStateExTrait};

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    // ------------------- Storage -------------------
    #[storage]
    struct Storage {
        numberOfTickets: u128,
        mappingTicket: LegacyMap::<u128, TicketDetail>,
        // Mapping hash of lottery address, lottery id, Array of picked numbers => picked numbers counter
        // using to show how many tickets have the same picked numbers
        combinationCounter: LegacyMap::<felt252, u128>,
        // Mapping user => list of tickets ID
        users: LegacyMap::<ContractAddress, List<u128>>,
        governanceContract: IGovernanceDispatcher,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage
    }

    // ----------------- Constructor -----------------
    #[constructor]
    fn constructor(
        ref self: ContractState, owner: ContractAddress, governanceAddress: ContractAddress
    ) {
        self.ownable.initializer(owner);
        self.governanceContract.write(IGovernanceDispatcher { contract_address: governanceAddress })
    }

    // ------------------- Structs -------------------
    #[derive(Drop, starknet::Store)]
    struct TicketDetail {
        lotteryAddress: ContractAddress,
        lotteryId: u128,
        pickedNumbers: List<u32>,
        payOut: u256,
        user: ContractAddress
    }

    // -------------------- Events --------------------
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        TicketCreated: TicketCreated,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[derive(Drop, starknet::Event)]
    struct TicketCreated {
        #[key]
        ticketId: u128,
        user: ContractAddress,
        lotteryAddress: ContractAddress,
        lotteryId: u128,
        pickedNumbers: Array::<u32>,
    }

    // --------------- External Accessors ---------------
    #[abi(embed_v0)]
    impl TicketImpl of ITicket<ContractState> {
        fn createTicket(
            ref self: ContractState,
            pickedNumbers: Array::<u32>,
            lotteryId: u128,
            userAddress: ContractAddress
        ) -> u128 {
            let lotteryAddress = get_caller_address();
            assert(
                self.governanceContract.read().validateLottery(lotteryAddress),
                'Lottery is inactive'
            );

            let ticketId = self.numberOfTickets.read() + 1;
            let mut newTicket = self.mappingTicket.read(ticketId);
            newTicket.lotteryAddress = lotteryAddress;
            newTicket.lotteryId = lotteryId;
            newTicket.pickedNumbers.from_array(@pickedNumbers);
            newTicket.user = userAddress;
            // Saving ticket detail with ID
            self.mappingTicket.write(ticketId, newTicket);

            let params = TicketHash {
                lotteryAddress, lotteryId, pickedNumbers: pickedNumbers.span()
            };

            // Counting number of combination of picked numbers
            self
                .combinationCounter
                .write(params.hashStruct(), self.combinationCounter.read(params.hashStruct()) + 1);
            // Pushing ticket id to user tickets mapping
            let mut userTickets = self.users.read(userAddress);
            userTickets.append(ticketId);
            self.users.write(userAddress, userTickets);

            self.numberOfTickets.write(self.numberOfTickets.read() + 1);

            self
                .emit(
                    TicketCreated {
                        ticketId, user: userAddress, lotteryAddress, lotteryId, pickedNumbers
                    }
                );

            ticketId
        }

        fn setPaidOut(ref self: ContractState, ticketId: u128, payOut: u256) {
            let lotteryAddress = get_caller_address();
            assert(
                self.governanceContract.read().validateLottery(lotteryAddress),
                'Lottery is inactive'
            );

            let mut ticket = self.mappingTicket.read(ticketId);
            ticket.payOut = payOut;
            self.mappingTicket.write(ticketId, ticket);
        }

        fn getTicketById(self: @ContractState, ticketId: u128) -> TicketGetter {
            let ticket = self.mappingTicket.read(ticketId);
            let ticketHash = TicketHash {
                lotteryAddress: ticket.lotteryAddress,
                lotteryId: ticket.lotteryId,
                pickedNumbers: ticket.pickedNumbers.array().span()
            };
            let sameCombinationCounter = self.combinationCounter.read(ticketHash.hashStruct());

            return TicketGetter {
                ticketId,
                lotteryAddress: ticket.lotteryAddress,
                lotteryId: ticket.lotteryId,
                pickedNumbers: ticket.pickedNumbers.array().span(),
                payOut: ticket.payOut,
                user: ticket.user,
                sameCombinationCounter
            };
        }

        fn getTicketByIds(self: @ContractState, ticketIds: Array::<u128>) -> Array::<TicketGetter> {
            let mut result = ArrayTrait::<TicketGetter>::new();
            let idsLength = ticketIds.len();

            let mut index: u32 = 0;
            let tickets = loop {
                if index == idsLength {
                    break result.clone();
                }

                let ticket = self.getTicketById(*ticketIds.at(index));
                result.append(ticket);
                index += 1;
            };

            tickets
        }


        fn getCombinationCounter(self: @ContractState, param: TicketHash) -> u128 {
            self.combinationCounter.read(param.hashStruct())
        }
    }

    // ----------------- View Accessors -----------------
    #[abi(per_item)]
    #[generate_trait]
    impl ViewAccessors of IViewAccessors {
        #[external(v0)]
        fn getSerializePickedNumbers(
            self: @ContractState, pickedNumbers: Array::<u32>
        ) -> Array::<felt252> {
            let mut pickedNumberFelt252 = ArrayTrait::<felt252>::new();
            pickedNumbers.serialize(ref pickedNumberFelt252);
            pickedNumberFelt252
        }

        #[external(v0)]
        fn changeGorvernanceContract(ref self: ContractState, newGorvernance: ContractAddress) {
            self.ownable.assert_only_owner();
            self
                .governanceContract
                .write(IGovernanceDispatcher { contract_address: newGorvernance });
        }

        #[external(v0)]
        fn getUserTickets(self: @ContractState, userAddress: ContractAddress) -> Span::<u128> {
            self.users.read(userAddress).array().span()
        }
    }

    // --------------- Private Accessors ---------------
    trait IStructHash<T> {
        fn hashStruct(self: @T) -> felt252;
    }

    impl StructHash of IStructHash<TicketHash> {
        fn hashStruct(self: @TicketHash) -> felt252 {
            let mut state = PedersenTrait::new(0);
            state = state.update_with(*self.lotteryAddress);
            state = state.update_with(*self.lotteryId);
            let mut pickedNumberFelt252 = ArrayTrait::<felt252>::new();
            self.pickedNumbers.serialize(ref pickedNumberFelt252);
            state = state.update_with(poseidon_hash_span(pickedNumberFelt252.span()));
            state.finalize()
        }
    }
}
