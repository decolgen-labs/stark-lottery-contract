use starknet::ContractAddress;

#[starknet::interface]
trait IGovernance<TContractState> {
    fn changeAdmin(ref self: TContractState, newAdmin: ContractAddress);
    fn changeFeeRecipient(ref self: TContractState, newFeeRecipient: ContractAddress);
    fn changeTicket(ref self: TContractState, newTicketContract: ContractAddress);
    fn changeRandomness(ref self: TContractState, newRandom: ContractAddress);
    fn changeMinimumPrice(ref self: TContractState, lottery: ContractAddress, newMinPrice: u256);
    fn changeInitialJackpot(
        ref self: TContractState, lottery: ContractAddress, newInitJackPot: u256
    );
    fn changeDurationStartTime(
        ref self: TContractState, lottery: ContractAddress, newDuration: u64
    );
    fn changeDurationBuyTicket(
        ref self: TContractState, lottery: ContractAddress, newDuration: u64
    );
    fn createLottery(
        ref self: TContractState,
        lottery: ContractAddress,
        minimumPrice: u256,
        durationStartTime: u64,
        durationBuyTicket: u64,
        initialJackpot: u256,
        increaseJackpot: u128,
        firstStartTime: u64,
    );
    fn cancelLottery(ref self: TContractState, lottery: ContractAddress);
    fn payTicketPrice(ref self: TContractState, buyer: ContractAddress);
    fn payoutWinner(
        ref self: TContractState, winner: ContractAddress, amount: u256, isJackpotWinner: bool
    );
    fn computeGrowingJackPot(
        self: @TContractState, lottery: ContractAddress, totalValue: u256
    ) -> u256;
    fn getAdmin(self: @TContractState) -> ContractAddress;
    fn getJackpotPool(self: @TContractState) -> u256;
    fn getRandomnessContract(self: @TContractState) -> ContractAddress;
    fn getTicketContract(self: @TContractState) -> ContractAddress;
    fn validateLottery(self: @TContractState, lottery: ContractAddress) -> bool;
    fn getMinimumPrice(self: @TContractState, lottery: ContractAddress) -> u256;
    fn getDurationStartTime(self: @TContractState, lottery: ContractAddress) -> u64;
    fn getDurationBuyTicket(self: @TContractState, lottery: ContractAddress) -> u64;
    fn getInitialJackpot(self: @TContractState, lottery: ContractAddress) -> u256;
    fn getFirstStartTime(self: @TContractState, lottery: ContractAddress) -> u64;
    fn getActiveLotteries(self: @TContractState) -> Span::<ContractAddress>;
}
