#[starknet::contract]
mod Ticket {
    use core::clone::Clone;
    use lottery::governance::interface::IGovernanceDispatcherTrait;
    use lottery::ticket::interface::{ITicket, TicketHash, TicketGetter};
    use lottery::governance::interface::IGovernanceDispatcher;
    use core::serde::Serde;
    use core::traits::TryInto;
    use core::array::ArrayTrait;
    use starknet::ContractAddress;
    use array::{Array, Span};
    use starknet::{get_caller_address};
    use alexandria_storage::list::{List, ListTrait};
    use pedersen::{PedersenTrait, HashState};
    use poseidon::poseidon_hash_span;
    use hash::{HashStateTrait, HashStateExTrait};

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
        governanceContract: IGovernanceDispatcher
    }

    // ----------------- Constructor -----------------
    #[constructor]
    fn constructor(ref self: ContractState, governanceAddress: ContractAddress) {
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
                pickedNumbers: ticket.pickedNumbers.array(),
                payOut: ticket.payOut,
                user: ticket.user,
                sameCombinationCounter
            };
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
