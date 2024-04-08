use starknet::ContractAddress;

// use as a param to map with the same combination picked numbers
#[derive(Drop, Serde)]
struct TicketHash {
    lotteryAddress: ContractAddress,
    lotteryId: u128,
    pickedNumbers: Span::<u32>,
}

#[derive(Drop, Copy, Serde)]
struct TicketGetter {
    ticketId: u128,
    lotteryAddress: ContractAddress,
    lotteryId: u128,
    pickedNumbers: Span::<u32>,
    payOut: u256,
    user: ContractAddress,
    sameCombinationCounter: u128,
}

#[starknet::interface]
trait ITicket<TContractState> {
    fn createTicket(
        ref self: TContractState,
        pickedNumbers: Array::<u32>,
        lotteryId: u128,
        userAddress: ContractAddress
    ) -> u128;
    fn setPaidOut(ref self: TContractState, ticketId: u128, payOut: u256);
    fn getCombinationCounter(self: @TContractState, param: TicketHash) -> u128;
    fn getTicketById(self: @TContractState, ticketId: u128) -> TicketGetter;
    fn getTicketByIds(self: @TContractState, ticketIds: Array::<u128>) -> Array::<TicketGetter>;
}
