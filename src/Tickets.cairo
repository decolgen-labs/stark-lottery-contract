use array::Array;
use starknet::ContractAddress;

#[starknet::interface]
trait ITicket<TContractState> {
    fn createTicket(
        ref self: TContractState,
        pickedNumbers: Array::<u32>,
        lotteryId: u128,
        userAddress: ContractAddress
    ) -> u128;
    fn setPaidOut(ref self: TContractState, ticketId: u128, payOut: u256);
}

#[starknet::contract]
mod Ticket {
    use core::serde::Serde;
    use core::traits::TryInto;
    use core::array::ArrayTrait;
    use super::{ContractAddress, ITicket, Array};
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

    #[derive(Drop, Serde)]
    struct TicketGetter {
        ticketId: u128,
        lotteryAddress: ContractAddress,
        lotteryId: u128,
        pickedNumbers: Array::<u32>,
        payOut: u256,
        user: ContractAddress,
        sameCombinationCounter: u128,
    }

    // use as a param to map with the same combination picked numbers
    #[derive(Drop)]
    struct TicketHash {
        lotteryAddress: ContractAddress,
        lotteryId: u128,
        pickedNumbers: Array::<u32>,
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
        user: ContractAddress
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
            let ticketId = self.numberOfTickets.read() + 1;
            let mut newTicket = self.mappingTicket.read(ticketId);
            newTicket.lotteryAddress = get_caller_address();
            newTicket.lotteryId = lotteryId;
            newTicket.pickedNumbers.from_array(@pickedNumbers);
            newTicket.user = userAddress;
            // Saving ticket detail with ID
            self.mappingTicket.write(ticketId, newTicket);

            let params = TicketHash {
                lotteryAddress: get_caller_address(),
                lotteryId: lotteryId,
                pickedNumbers: pickedNumbers
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

            self.emit(TicketCreated { ticketId, user: userAddress });

            ticketId
        }

        fn setPaidOut(ref self: ContractState, ticketId: u128, payOut: u256) {}
    }

    // ----------------- View Accessors -----------------
    #[abi(per_item)]
    #[generate_trait]
    impl ViewAccessors of IViewAccessors {
        #[external(v0)]
        fn getTicketById(self: @ContractState, ticketId: u128) -> TicketGetter {
            let ticket = self.mappingTicket.read(ticketId);
            let ticketHash = TicketHash {
                lotteryAddress: ticket.lotteryAddress,
                lotteryId: ticket.lotteryId,
                pickedNumbers: ticket.pickedNumbers.array()
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

    #[generate_trait]
    impl Private of PrivateTrait {}
}
