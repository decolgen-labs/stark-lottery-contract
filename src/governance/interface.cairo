use starknet::ContractAddress;
use array::Array;

#[starknet::interface]
trait IGovernance<TContractState> {
    fn changeAdmin(ref self: TContractState, newAdmin: ContractAddress);
    fn changeRandomness(ref self: TContractState, newRandom: ContractAddress);
    fn changeFee(ref self: TContractState, newFee: u128);
    fn changeMinimumPrice(ref self: TContractState, lottery: ContractAddress, newMinPrice: u256);
    fn changeInitialJackpot(
        ref self: TContractState, lottery: ContractAddress, newInitJackPot: u256
    );
    fn changeDuration(ref self: TContractState, lottery: ContractAddress, newDuration: u64);
    fn createLottery(
        ref self: TContractState,
        lottery: ContractAddress,
        minimumPrice: u256,
        duration: u64,
        initialJackpot: u256,
        firstDrawTime: u64
    );
    fn cancelLottery(ref self: TContractState, lottery: ContractAddress);
    fn getAdmin(self: @TContractState) -> ContractAddress;
    fn validateLottery(self: @TContractState, lottery: ContractAddress) -> bool;
    fn getMinimumPrice(self: @TContractState, lottery: ContractAddress) -> u256;
    fn getDuration(self: @TContractState, lottery: ContractAddress) -> u64;
    fn getInitialJackpot(self: @TContractState, lottery: ContractAddress) -> u256;
    fn getFirstDrawtime(self: @TContractState, lottery: ContractAddress) -> u64;
    fn getActiveLotteries(self: @TContractState) -> Array::<ContractAddress>;
}
