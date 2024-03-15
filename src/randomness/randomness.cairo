#[starknet::contract]
mod Randomness {
    use lottery::randomness::interface::{
        IRandomness, IPragmaRandomnessDispatcher, IPragmaRandomnessDispatcherTrait
    };
    use lottery::governance::interface::{IGovernanceDispatcher, IGovernanceDispatcherTrait};
    use openzeppelin::access::ownable::OwnableComponent;
    use openzeppelin::token::erc20::interface::{IERC20CamelDispatcher, IERC20CamelDispatcherTrait};
    use starknet::{
        ContractAddress, get_caller_address, get_block_timestamp, get_contract_address,
        get_block_info
    };
    use pedersen::{PedersenTrait, HashState};
    use hash::{HashStateTrait, HashStateExTrait};
    use integer::{BoundedU64};
    use array::{Array, ArrayTrait};

    const NUM_WORDS_FOR_REQUEST_RANDOMNESS: u64 = 1;

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);

    #[abi(embed_v0)]
    impl OwnableImpl = OwnableComponent::OwnableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        vrfContract: ContractAddress,
        ETHAddress: ContractAddress,
        minBlockStorage: u64,
        publishDelay: u64,
        lastRandomStorage: LegacyMap::<ContractAddress, felt252>,
        callbackFeeLimit: u128,
        governanceContract: IGovernanceDispatcher,
        totalETHBalance: u256,
        requestIdtoAddress: LegacyMap::<u64, ContractAddress>,
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        ETHAddress: ContractAddress,
        vrfContract: ContractAddress,
        governanceContract: ContractAddress
    ) {
        self.ownable.initializer(owner);
        self.vrfContract.write(vrfContract);
        self.ETHAddress.write(ETHAddress);
        self.publishDelay.write(1);
        self
            .governanceContract
            .write(IGovernanceDispatcher { contract_address: governanceContract });
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnableEvent: OwnableComponent::Event,
    }

    #[abi(embed_v0)]
    impl RandomnessImpl of IRandomness<ContractState> {
        fn getRandom(ref self: ContractState, signature: Span<felt252>) {
            let governance = self.governanceContract.read();
            let lottery = get_caller_address();
            assert(governance.validateLottery(lottery), 'Invalid lottery');

            let vrfContract = self.vrfContract.read();
            let vrfContractDispatcher = IPragmaRandomnessDispatcher {
                contract_address: vrfContract
            };

            let computeFee = vrfContractDispatcher.compute_premium_fee(lottery);
            // IERC20CamelDispatcher { contract_address: self.ETHAddress.read() }
            //     .approve(vrfContract, computeFee.into());

            let numWord: u64 = 1;
            let requestId = vrfContractDispatcher
                .request_random(
                    self.getSeed(signature),
                    get_contract_address(),
                    computeFee,
                    self.publishDelay.read(),
                    numWord,
                    ArrayTrait::<felt252>::new()
                );

            let currentBlockNumber = get_block_info().unbox().block_number;
            self.minBlockStorage.write(currentBlockNumber + self.publishDelay.read());
            self.requestIdtoAddress.write(requestId, lottery);
        }

        fn receive_random_words(
            ref self: ContractState,
            requestor_address: ContractAddress,
            request_id: u64,
            random_words: Span<felt252>,
            calldata: Array<felt252>
        ) {
            let caller = get_caller_address();
            assert(caller == self.getVRFContract(), 'Caller must be randomess');

            let lottery = self.requestIdtoAddress.read(request_id);
            assert(lottery.is_non_zero(), 'Invalid Request Id');

            assert(requestor_address == get_contract_address(), 'requestor is not self');

            let currentBlock = get_block_info().unbox().block_number;
            let minBlock = self.minBlockStorage.read();
            assert(minBlock <= currentBlock, 'block number issue');

            let random_word = *random_words.at(0);
            self.lastRandomStorage.write(lottery, random_word);
        }
    }

    #[abi(per_item)]
    #[generate_trait]
    impl AdditionalAccessors of AdditionalAccessorsTrait {
        #[external(v0)]
        fn updateVRFContract(ref self: ContractState, newVRFContract: ContractAddress) {
            self.ownable.assert_only_owner();
            self.vrfContract.write(newVRFContract);
        }

        #[external(v0)]
        fn updateMinBlockStorage(ref self: ContractState, minBlockStorage: u64) {
            self.ownable.assert_only_owner();
            self.minBlockStorage.write(minBlockStorage);
        }

        #[external(v0)]
        fn updatePublishDelay(ref self: ContractState, publishDelay: u64) {
            self.ownable.assert_only_owner();
            self.publishDelay.write(publishDelay);
        }

        #[external(v0)]
        fn updateCallbackFeeLimit(ref self: ContractState, callbackFeeLimit: u128) {
            self.ownable.assert_only_owner();
            self.callbackFeeLimit.write(callbackFeeLimit);
        }

        #[external(v0)]
        fn updateGovernanceContract(
            ref self: ContractState, newgovernanceContract: ContractAddress
        ) {
            self.ownable.assert_only_owner();
            self
                .governanceContract
                .write(IGovernanceDispatcher { contract_address: newgovernanceContract });
        }

        #[external(v0)]
        fn topupETH(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            assert(amount > 0, 'Invalid amount');
            IERC20CamelDispatcher { contract_address: self.ETHAddress.read() }
                .transferFrom(get_caller_address(), get_contract_address(), amount);

            self.totalETHBalance.write(self.totalETHBalance.read() + amount);
        }

        #[external(v0)]
        fn withdrawBalance(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            assert(amount <= self.getTotalETHBalance(), 'Insufficient Balance');

            IERC20CamelDispatcher { contract_address: self.ETHAddress.read() }
                .transfer(get_caller_address(), amount);

            self.totalETHBalance.write(self.totalETHBalance.read() - amount);
        }

        #[external(v0)]
        fn aproveVRF(ref self: ContractState, amount: u256) {
            self.ownable.assert_only_owner();
            IERC20CamelDispatcher { contract_address: self.ETHAddress.read() }
                .approve(self.getVRFContract(), amount);
        }

        #[external(v0)]
        fn getTotalETHBalance(self: @ContractState) -> u256 {
            self.totalETHBalance.read()
        }

        #[external(v0)]
        fn getLotteryByRequestId(self: @ContractState, requestId: u64) -> ContractAddress {
            self.requestIdtoAddress.read(requestId)
        }

        #[external(v0)]
        fn getVRFContract(self: @ContractState) -> ContractAddress {
            self.vrfContract.read()
        }

        #[external(v0)]
        fn changeVRFContract(ref self: ContractState, newVRFContract: ContractAddress) {
            self.ownable.assert_only_owner();
            self.vrfContract.write(newVRFContract);
        }

        #[external(v0)]
        fn changeGovernance(ref self: ContractState, newgovernance: ContractAddress) {
            self.ownable.assert_only_owner();
            self
                .governanceContract
                .write(IGovernanceDispatcher { contract_address: newgovernance });
        }
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn getSeed(self: @ContractState, signature: Span<felt252>) -> u64 {
            let sig_r = *signature.at(0);
            let sig_s = *signature.at(1);
            let blockTime = get_block_timestamp();

            let mut hash = PedersenTrait::new(0);
            hash = hash.update_with(sig_r);
            hash = hash.update_with(sig_s);
            hash = hash.update_with(blockTime);
            hash = hash.update_with(3);
            let result: u256 = hash.finalize().into();
            let mut result_u128 = result.low / BoundedU64::max().into();
            let result_u64: u64 = loop {
                if result_u128 < BoundedU64::max().into() {
                    break result_u128.try_into().unwrap();
                }

                result_u128 - 1;
            };

            result_u64
        }
    }
}

