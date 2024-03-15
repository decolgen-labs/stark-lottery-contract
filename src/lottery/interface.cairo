use array::Array;
use starknet::ContractAddress;
use alexandria_storage::list::List;

#[derive(Drop, starknet::Store)]
struct LotteryDetail {
    lotteryId: u128, // Lottery Id
    minimumPrice: u256, // Minimum ticket price for minimum picked numbers
    state: u8, // State of the lottery 0 = Closed, 1 = open, 2 = drawing
    drawTime: u64, // The lottery draw time
    totalValue: u256, // Total value of tickets sold playing this lottery draw
    jackpot: u256, // Jackpot amount for this lottery draw
    drawnNumbers: List<u32>
}

#[derive(Drop, Serde)]
struct LotteryGetterStruct {
    id: u128,
    minimumPrice: u256,
    state: u8,
    drawTime: u64,
    drawnNumbers: Span::<u32>,
    amountOfTickets: u128,
    totalValue: u256,
    jackpot: u256,
    jackpotWinners: u128,
}

#[starknet::interface]
trait ILottery<TContractState> {
    fn startNewLottery(ref self: TContractState);
    fn buyTicket(ref self: TContractState, pickedNumbers: Span::<u32>);
    fn startDrawing(ref self: TContractState);
    fn fulfillDrawing(ref self: TContractState, randomWord: felt252);
    fn claimRewards(ref self: TContractState, ticketId: u128);
    fn getCurrentLottery(self: @TContractState) -> LotteryGetterStruct;
    fn getLotteryById(self: @TContractState, lotteryId: u128) -> LotteryGetterStruct;
    fn getLotteryByIds(
        self: @TContractState, lotteryIds: Span::<u128>
    ) -> Span::<LotteryGetterStruct>;
}
