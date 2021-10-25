---
title: "EVM运行原理"
date: 2021-10-18
lastmod: 2021-10-18
draft: false
tags: ["Go", "ETH", "Blockchain"]

toc: true

---

# ETH-EVM理解

## 前言

EVM是以太坊虚拟机，其中`EVMIterpreter`是运行合约代码的解释器，下面我们通过一个合约来具体分析EVM是如何在以太坊工作的

## 测试合约

- 以太坊合约是通过`solidity`语言编写的，经过`solidity`的编译器编译成字节码，[编译器源码](https://github.com/ethereum/solidity)
- 可以通过[Remix](https://github.com/ethereum/remix-project)进行合约代码的编写和部署，`remix`相当于一个`IDE`，可以本地部署(推荐)，或者使用[在线编辑](https://remix.ethereum.org/)

1. 合约代码

   ```
   // SPDX-License-Identifier: GPL-3.0
   pragma solidity >=0.7.0 <0.9.0;
   
   // 嵌套合约
   //contract TestContractInner {
   //    TestContract con;
   //    constructor(address addr) payable {
   //        con = TestContract(addr);
   //    }
   //    
   //    function balanceOf(address account) public view returns (uint256) {
   //        return con.balanceOf(account);
   //    }
   //}
   
   contract TestContract {
       // 用来创建合约时的初始化   
       // constructor() payable {}

       // 用来测试erc20 token
       mapping(address => uint256) private _balances;
   
       function addBalance(address payable sender) public {
           // 用来测试erc20 token
           _balances[sender] += 100000000000000000;
       }
       
       function transfer(address payable sender) public {
           // 用来测试 internal tx
           sender.transfer(10);
       }
           
       function balanceOf(address account) public view returns (uint256) {
           return _balances[account];
       }
   }
   ```

2. 编译出来的字节码 bytecode

   ```
   608060405234801561001057600080fd5b5061038b806100206000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80631a6952301461004657806370a0823114610062578063b5cef24a14610092575b600080fd5b610060600480360381019061005b91906101f8565b6100ae565b005b61007c600480360381019061007791906101cb565b6100f9565b6040516100899190610234565b60405180910390f35b6100ac60048036038101906100a791906101f8565b610141565b005b8073ffffffffffffffffffffffffffffffffffffffff166108fc600a9081150290604051600060405180830381858888f193505050501580156100f5573d6000803e3d6000fd5b5050565b60008060008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020549050919050565b67016345785d8a00006000808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000206000828254610197919061024f565b9250508190555050565b6000813590506101b081610327565b92915050565b6000813590506101c58161033e565b92915050565b6000602082840312156101e1576101e0610322565b5b60006101ef848285016101a1565b91505092915050565b60006020828403121561020e5761020d610322565b5b600061021c848285016101b6565b91505092915050565b61022e816102e9565b82525050565b60006020820190506102496000830184610225565b92915050565b600061025a826102e9565b9150610265836102e9565b9250827fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0382111561029a576102996102f3565b5b828201905092915050565b60006102b0826102c9565b9050919050565b60006102c2826102c9565b9050919050565b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b6000819050919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b600080fd5b610330816102a5565b811461033b57600080fd5b50565b610347816102b7565b811461035257600080fd5b5056fea2646970667358221220379c537446a8d2ba546abc18269ab68941e5818a4966a02c7311b66cdd7763c164736f6c63430008070033
   ```

   字节码可以根据`jumpTable`翻译成特定的操作（op），是由1个字节组成（有些是参数，不一定是1个字节），上面的字节码可以翻译成如下的操作码

   ```
   PUSH1 0x80 PUSH1 0x40 MSTORE CALLVALUE DUP1 ISZERO PUSH2 0x10 JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP PUSH2 0x38B DUP1 PUSH2 0x20 PUSH1 0x0 CODECOPY PUSH1 0x0 RETURN INVALID PUSH1 0x80 PUSH1 0x40 MSTORE CALLVALUE DUP1 ISZERO PUSH2 0x10 JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP PUSH1 0x4 CALLDATASIZE LT PUSH2 0x41 JUMPI PUSH1 0x0 CALLDATALOAD PUSH1 0xE0 SHR DUP1 PUSH4 0x1A695230 EQ PUSH2 0x46 JUMPI DUP1 PUSH4 0x70A08231 EQ PUSH2 0x62 JUMPI DUP1 PUSH4 0xB5CEF24A EQ PUSH2 0x92 JUMPI JUMPDEST PUSH1 0x0 DUP1 REVERT JUMPDEST PUSH2 0x60 PUSH1 0x4 DUP1 CALLDATASIZE SUB DUP2 ADD SWAP1 PUSH2 0x5B SWAP2 SWAP1 PUSH2 0x1F8 JUMP JUMPDEST PUSH2 0xAE JUMP JUMPDEST STOP JUMPDEST PUSH2 0x7C PUSH1 0x4 DUP1 CALLDATASIZE SUB DUP2 ADD SWAP1 PUSH2 0x77 SWAP2 SWAP1 PUSH2 0x1CB JUMP JUMPDEST PUSH2 0xF9 JUMP JUMPDEST PUSH1 0x40 MLOAD PUSH2 0x89 SWAP2 SWAP1 PUSH2 0x234 JUMP JUMPDEST PUSH1 0x40 MLOAD DUP1 SWAP2 SUB SWAP1 RETURN JUMPDEST PUSH2 0xAC PUSH1 0x4 DUP1 CALLDATASIZE SUB DUP2 ADD SWAP1 PUSH2 0xA7 SWAP2 SWAP1 PUSH2 0x1F8 JUMP JUMPDEST PUSH2 0x141 JUMP JUMPDEST STOP JUMPDEST DUP1 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND PUSH2 0x8FC PUSH1 0xA SWAP1 DUP2 ISZERO MUL SWAP1 PUSH1 0x40 MLOAD PUSH1 0x0 PUSH1 0x40 MLOAD DUP1 DUP4 SUB DUP2 DUP6 DUP9 DUP9 CALL SWAP4 POP POP POP POP ISZERO DUP1 ISZERO PUSH2 0xF5 JUMPI RETURNDATASIZE PUSH1 0x0 DUP1 RETURNDATACOPY RETURNDATASIZE PUSH1 0x0 REVERT JUMPDEST POP POP JUMP JUMPDEST PUSH1 0x0 DUP1 PUSH1 0x0 DUP4 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND DUP2 MSTORE PUSH1 0x20 ADD SWAP1 DUP2 MSTORE PUSH1 0x20 ADD PUSH1 0x0 KECCAK256 SLOAD SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH8 0x16345785D8A0000 PUSH1 0x0 DUP1 DUP4 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND DUP2 MSTORE PUSH1 0x20 ADD SWAP1 DUP2 MSTORE PUSH1 0x20 ADD PUSH1 0x0 KECCAK256 PUSH1 0x0 DUP3 DUP3 SLOAD PUSH2 0x197 SWAP2 SWAP1 PUSH2 0x24F JUMP JUMPDEST SWAP3 POP POP DUP2 SWAP1 SSTORE POP POP JUMP JUMPDEST PUSH1 0x0 DUP2 CALLDATALOAD SWAP1 POP PUSH2 0x1B0 DUP2 PUSH2 0x327 JUMP JUMPDEST SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 DUP2 CALLDATALOAD SWAP1 POP PUSH2 0x1C5 DUP2 PUSH2 0x33E JUMP JUMPDEST SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH1 0x20 DUP3 DUP5 SUB SLT ISZERO PUSH2 0x1E1 JUMPI PUSH2 0x1E0 PUSH2 0x322 JUMP JUMPDEST JUMPDEST PUSH1 0x0 PUSH2 0x1EF DUP5 DUP3 DUP6 ADD PUSH2 0x1A1 JUMP JUMPDEST SWAP2 POP POP SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH1 0x20 DUP3 DUP5 SUB SLT ISZERO PUSH2 0x20E JUMPI PUSH2 0x20D PUSH2 0x322 JUMP JUMPDEST JUMPDEST PUSH1 0x0 PUSH2 0x21C DUP5 DUP3 DUP6 ADD PUSH2 0x1B6 JUMP JUMPDEST SWAP2 POP POP SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH2 0x22E DUP2 PUSH2 0x2E9 JUMP JUMPDEST DUP3 MSTORE POP POP JUMP JUMPDEST PUSH1 0x0 PUSH1 0x20 DUP3 ADD SWAP1 POP PUSH2 0x249 PUSH1 0x0 DUP4 ADD DUP5 PUSH2 0x225 JUMP JUMPDEST SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH2 0x25A DUP3 PUSH2 0x2E9 JUMP JUMPDEST SWAP2 POP PUSH2 0x265 DUP4 PUSH2 0x2E9 JUMP JUMPDEST SWAP3 POP DUP3 PUSH32 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF SUB DUP3 GT ISZERO PUSH2 0x29A JUMPI PUSH2 0x299 PUSH2 0x2F3 JUMP JUMPDEST JUMPDEST DUP3 DUP3 ADD SWAP1 POP SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH2 0x2B0 DUP3 PUSH2 0x2C9 JUMP JUMPDEST SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH1 0x0 PUSH2 0x2C2 DUP3 PUSH2 0x2C9 JUMP JUMPDEST SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH1 0x0 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF DUP3 AND SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH1 0x0 DUP2 SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH32 0x4E487B7100000000000000000000000000000000000000000000000000000000 PUSH1 0x0 MSTORE PUSH1 0x11 PUSH1 0x4 MSTORE PUSH1 0x24 PUSH1 0x0 REVERT JUMPDEST PUSH1 0x0 DUP1 REVERT JUMPDEST PUSH2 0x330 DUP2 PUSH2 0x2A5 JUMP JUMPDEST DUP2 EQ PUSH2 0x33B JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP JUMP JUMPDEST PUSH2 0x347 DUP2 PUSH2 0x2B7 JUMP JUMPDEST DUP2 EQ PUSH2 0x352 JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP JUMP INVALID LOG2 PUSH5 0x6970667358 0x22 SLT KECCAK256 CALLDATACOPY SWAP13 MSTORE8 PUSH21 0x46A8D2BA546ABC18269AB68941E5818A4966A02C73 GT 0xB6 PUSH13 0xDD7763C164736F6C6343000807 STOP CALLER
   ```

## 部署到测试链

1. 这里可以通过`Remix`进行部署，其中有3种方式
    1. JavaScript VM：js实现的EVM
    2. Injected Web3：浏览器的钱包插件
    3. Web3 Provider：直接通过web3建立连接，注意需要在启动时添加http和跨域参数`--http --http.corsdomain https://remix.ethereum.org`
2. 这里我DEBUG了一个ETH测试链，然后本地跑起来，再通过`Web3 Provider`的形式直连，这样就可以很方便的进行DEBUG了，具体流程可以谷歌

## 部署的运行逻辑

### 首先看部署合约产生的交易

```
{
    "type":"0x2", // 这里的交易类型是DynamicFeeTxType，是EIP-1559的新协议使用的交易
    "nonce":"0x1",
    "gasPrice":null,
    "maxPriorityFeePerGas":"0x3b9aca00", // EIP-1559新增，计算手续费使用
    "maxFeePerGas":"0x77359400",                 // EIP-1559新增，计算手续费使用
    "gas":"0x3cb2a",
    "value":"0x0",                                             // value是0
    "input":"0x608060405234801561001057600080fd5b5061038b806100206000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80631a6952301461004657806370a0823114610062578063b5cef24a14610092575b600080fd5b610060600480360381019061005b91906101f8565b6100ae565b005b61007c600480360381019061007791906101cb565b6100f9565b6040516100899190610234565b60405180910390f35b6100ac60048036038101906100a791906101f8565b610141565b005b8073ffffffffffffffffffffffffffffffffffffffff166108fc600a9081150290604051600060405180830381858888f193505050501580156100f5573d6000803e3d6000fd5b5050565b60008060008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020549050919050565b67016345785d8a00006000808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000206000828254610197919061024f565b9250508190555050565b6000813590506101b081610327565b92915050565b6000813590506101c58161033e565b92915050565b6000602082840312156101e1576101e0610322565b5b60006101ef848285016101a1565b91505092915050565b60006020828403121561020e5761020d610322565b5b600061021c848285016101b6565b91505092915050565b61022e816102e9565b82525050565b60006020820190506102496000830184610225565b92915050565b600061025a826102e9565b9150610265836102e9565b9250827fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0382111561029a576102996102f3565b5b828201905092915050565b60006102b0826102c9565b9050919050565b60006102c2826102c9565b9050919050565b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b6000819050919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b600080fd5b610330816102a5565b811461033b57600080fd5b50565b610347816102b7565b811461035257600080fd5b5056fea2646970667358221220560a7db3964c18024094ece0c5379f001e8716caeb3ab0613b67cd05f5a600f964736f6c63430008070033", // input是合约的字节码
    "to":null, // to是nil
    "chainId":"0x7c8",
    "hash":"0xa3980499a36b7c0d16fc565a473179c7a48131aea586e67da24a67b4272e1330"
}
```

所以当to是nil时，是一个创建合约的交易

### 代码运行

省略交易传递的种种，我们直接到交易运行处

1. ApplyMessage入口

   ```
   // core/state_transition.go
   // 接受交易运行的入口
   func ApplyMessage(evm *vm.EVM, msg Message, gp *GasPool) (*ExecutionResult, error) {
     return NewStateTransition(evm, msg, gp).TransitionDb()
   }
   ```

2. TransitionDb判断交易

   ```
   // core/state_transition.go
   func (st *StateTransition) TransitionDb() (*ExecutionResult, error) {
     // ...忽略其他代码
     contractCreation := msg.To() == nil
     // 可以看到，代码代码中也是通过判断To是否是空来运行不同逻辑的
     // 当To是nil时，运行Create方法
     if contractCreation {
       ret, _, st.gas, vmerr = st.evm.Create(sender, st.data, st.gas, st.value)
     } else {
       st.state.SetNonce(msg.From(), st.state.GetNonce(sender.Address())+1)
       ret, st.gas, vmerr = st.evm.Call(sender, st.to(), st.data, st.gas, st.value)
     }
   }
   ```

3. evm.Create创建合约

   ```
   // core/vm/evm.go
   func (evm *EVM) Create(caller ContractRef, code []byte, gas uint64, value *big.Int) (ret []byte, contractAddr common.Address, leftOverGas uint64, err error) {
     // 首先计算合约地址
     contractAddr = crypto.CreateAddress(caller.Address(), evm.StateDB.GetNonce(caller.Address()))
     // 调用内部创建方法
     return evm.create(caller, &codeAndHash{code: code}, gas, value, contractAddr)
   }
   ```

4. crypto.CreateAddress计算合约地址

   ```
   // crypto/crypto.go
   func CreateAddress(b common.Address, nonce uint64) common.Address {
     // 可以看到合约地址是 调用者的地址+交易的nonce进行rlp编码后，再通过Keccake256计算取前12位
     // 得到的，所以完全可以根据一笔交易计算次合约地址
     data, _ := rlp.EncodeToBytes([]interface{}{b, nonce})
     return common.BytesToAddress(Keccak256(data)[12:])
   }
   ```

5. evm.create内部创建

   ```
   func (evm *EVM) create(caller ContractRef, codeAndHash *codeAndHash, gas uint64, value *big.Int, address common.Address) ([]byte, common.Address, uint64, error) {
     // ...忽略其他代码
     // 数据库创建合约
     evm.StateDB.CreateAccount(address)
     // 调用transfer代码，此时会从调用者的余额转装到合约地址
     evm.Context.Transfer(evm.StateDB, caller.Address(), address, value)
     // 实例化一个合约对象
     contract := NewContract(caller, AccountRef(address), value, gas)
     // 将字节码写入contract
     contract.SetCodeOptionalHash(&address, codeAndHash)
     // 运行解释器，运行字节码（重要，后面深入展开）
     ret, err := evm.interpreter.Run(contract, nil, false)
     // 存储合约
     evm.StateDB.SetCode(address, ret)
     // 返回运行结果
     return ret, address, contract.Gas, err
   }
   ```
### 总结
1. 可以看到创建合约的交易是通过`to=nil`来标记的
2. 可以通过发送者的`address+nonce`计算合约地址
3. 合约最终会通过解释器运行

## 调用的运行逻辑
首先我们通过调用`balanceOf()`这个方法看一下合约调用逻辑
### 调用合约的方法-不上链
在调用balanceOf之后，我们发现并没有在`EthAPIBackend.SendTx`处捕获到断点，查看`remix`状态，发现
调用的是eth_call这个api，通过检查注册的API，最终在`PublicBlockChainAPI.Call`找到了方法，然后通过`core.ApplyMessage`来执行调用
### PublicBlockChainAPI.Call
简而言之，Call方法主要是进行不上链的操作调用，直接从数据库获取状态，首先看一下传入的参数
```
{
    "from":"0x8d07a5ba716a12a435ec31303049ebf81ca08cc6",
    "to":"0x941b77f8e5248930e5e52029c830994d876eb3a2", // 合约地址
    "gas":"0x2dc6c0",                                    
    "gasPrice":null,
    "maxFeePerGas":null,
    "maxPriorityFeePerGas":null,
    "value":"0x0",
    "nonce":null,
    "data":"0x70a082310000000000000000000000008d07a5ba716a12a435ec31303049ebf81ca08cc6", // 调用的数据
    "input":null
}
```
其中data字段包含了调用的合约方法和参数
1. st.evm.Call运行合约
   ```
   // 直接转账，如果value是0也会进行调用
   // 所以如果调用合约时value的值不为0，则会被发送到合约的地址下
   evm.Context.Transfer(evm.StateDB, caller.Address(), addr, value)
   // 获取合约的字节码
   code := evm.StateDB.GetCode(addr)
   // 执行合约
   ret, err = evm.interpreter.Run(contract, input, false)
   ```
#### 方法和参数生成
data字段的值是由方法和参数组成的，其中方法名为
```
crypto.Keccak256Hash([]byte("balanceOf(address)"))
// 0x70a08231b98ef4ca268c9cc3f6b4590e4bfec28280db06bb5d45e689f2a360be
```
其中参数是参数类型，然后取前4个字节作为方法名称，最后生成为`0x70a08231`<br/>
然后参数为hexString编码，如果string长度不够64，则往前补齐0，最后将方法名和参数拼接在一起：
```
0x70a08231
  0000000000000000000000008d07a5ba716a12a435ec31303049ebf81ca08cc6 // len = 64
```
更复杂的拼接逻辑说明请看[官方文档](https://solidity-cn.readthedocs.io/zh/develop/abi-spec.html)

### 调用合约的方法-上链
接下来我们调用`addBalance()`这个方法来进行上链数据的调用，看一下代码运行。
#### 交易结构
```
{
    "type":"0x2",
    "nonce":"0x1",
    "gasPrice":null,
    "maxPriorityFeePerGas":"0x3b9aca00",
    "maxFeePerGas":"0x77359400",
    "gas":"0xad20",
    "value":"0x0",
    "input":"0xb5cef24a000000000000000000000000d80e810da222e282112f601f35040a24da7f770e",
    "to":"0x950c9afb7d324c0f645e2ba53059d11e2437518b",
    "chainId":"0x7c8",
    "hash":"0xe87dd5ce0930b8cddd1c573ed819f675cc585ab9c009670b8f270d92bb064677"
}
```
可以看到这里的to是合约地址，然后input是合约方法和参数

### 代码运行
上面我们已经知道，在TransitionDb时进行的判断，当to不是nil时，进行st.evm.Call调用
1. st.evm.Call
   ```
   // core/vm/evm.go
   func (evm *EVM) Call(caller ContractRef, addr common.Address, input []byte, gas uint64, value *big.Int) (ret []byte, leftOverGas uint64, err error) {
     // 往合约地址转账
     evm.Context.Transfer(evm.StateDB, caller.Address(), addr, value)
     // 从数据库获取CODE，是创建时存入的
     code := evm.StateDB.GetCode(addr)
     // 新建一个合约对象
     contract := NewContract(caller, AccountRef(addrCopy), value, gas)
     // 设置code
     contract.SetCallCode(&addrCopy, evm.StateDB.GetCodeHash(addrCopy), code)
     // 解释器运行，此时input不为空
     ret, err = evm.interpreter.Run(contract, input, false)
   }
   ```
2. evm.interpreter.Run解释器
   ```
   // core/vm/interpreter.go
   func (in *EVMInterpreter) Run(contract *Contract, input []byte, readOnly bool) (ret []byte, err error) {
     // 计数器，用来表示读取的code下标
     pc = uint64(0) // program counter
     // 获取操作码
     op = contract.GetOp(pc)
     // 根据操作码获取对应的操作对象
     operation := in.cfg.JumpTable[op]
     // 运行操作对象的execute方法
     // 这个方法是最重要的，具体需要查看JumpTable里对应的方法
     res, err = operation.execute(&pc, in, callContext)
   }
   ```
### 总结
1. 当to和input不为空时进行合约调用
2. 合约调用需要interpreter解释器来运行
3. 最终是根据操作码的execute方法一步一步的执行

## EVM解释器运行逻辑
解释器相当于根据字节码一个字节一个字节的解析，下面我们来分下一下上面合约的解释过程，建议结合`REMIX`的DEBUG模式一起使用
### 创建合约的执行过程
index表示字节码下表，ops表示字节翻译成的操作码（具体可以看jumpTable)
```
:index      :ops          :comment
0-1         PUSH1 0x80    // 将 0x80 压入stack
2-3         PUSH1 0x40    // 将 0x40 压入stack
4           MSTORE        // 将 0x40 和 0x80 pop出来，memory中生成 32 字节的空间，同时将 0x80 写入创建的bytes中
5           CALLVALUE     // 将调用合约时传入的value压入stack
6           DUP1          // 将stack[len-1]的元素压入stack里（stack实际上是一个slice）,此时是将value值再次压入stack中
7           ISZERO        // 获取stack最顶的元素，判断是否为0，如果为0，则设置为1
8-10        PUSH2 0x10    // push2将后面两个byte（0x00和0x10）转为int，然后压入stack，这里没有0x00是因为被省略了，具体可以看debug时的Code，在index=9存在一个0字节
11          JUMPI         // 将上面的 pos=0x0010 和 cond=0x01 pop出来，然后跳转到0x0010（16）处，即下面的JUMPDEST处
16          JUMPDEST      // 返回空
17          POP           // stack pop
18-20       PUSH2 0x38B   // 同上面的PUSH2，将 0x00和0x38B 转为int后压入stack
21          DUP1          // 将上面的值再次压入stack
22-24       PUSH2 0x20    // 将 0x00和0x20 转为int后压入stack
25-26       PUSH1 0x0     // 将 0x0 压入stack
27          CODECOPY      // pop 3个值，分别对应memOffset，codeOffet字节码中的下标，length字节长度，所以是获取CODE[32:939]（CODE总长就是939，所以相当于到末尾）的字节，然后复制到memory的memOffset开始的地方
28-29       PUSH1 0x0     // 0x0 压入stack
30          RETURN        // offset=0x0, size=0x38B，pop两个值，然后返回memory指向的bytes
```
到这里创建合约的代码就执行完毕了，后面在EVM中会将ret保存在数据库中。所以调用时执行合约的代码是在return之后的字节码，创建只是初始化一些全局变量等。

### balanceOf 合约方法的执行过程
我们首先通过上面的`balanceOf`来看一下合约调用时的解释过程
#### input
```
0x70a082310000000000000000000000008d07a5ba716a12a435ec31303049ebf81ca08cc6
```
#### 执行过程
首先是从数据库加载`CODE`，注意此时的`CODE`是创建时的`ret`，即创建时传入的`data[32:]`
```
:index      :ops             :comment
0-1         PUSH1 0x80      
2-3         PUSH1 0x40 
4           MSTORE 
5           CALLVALUE 
6           DUP1 
7           ISZERO 
8-10        PUSH2 0x10 
11          JUMPI            // pop两个值，第一个0x10作为offset，跳转到offset
16          JUMPDEST 
17          POP
18-19       PUSH1 0x4 
20          CALLDATASIZE     // 将我们输入的input的长度的值(36)压入栈 
21          LT               // 栈取出input的长度值与栈顶元素比较（0x4），如果小于，栈顶元素0x4变为0x1，否则变为0x0
22-24       PUSH2 0x41      
25          JUMPI            // offset=0x41(十进制为65)，由于cond为0， 所以此时不跳转
26-27       PUSH1 0x0
28          CALLDATALOAD     // 获取input[:32]存入当前的栈顶元素内 
29-30       PUSH1 0xE0      
31          SHR              // 将CALLDATALOAD设置的值右移动224（0xE0）位。因为32个字节中只使用了4个字节，所以是224位  
32          DUP1           
33-37       PUSH4 0x1A695230 // 将1A695230压入栈中 
38          EQ               // pop 1A695230的值，并与栈顶元素比较（即input[:32])，如果相等，将栈顶值设为1，否则，设置为0，这里设置为0，因为不等
39-41       PUSH2 0x46        
42          JUMPI            // pop offset和cond，由于cond为0，所以不跳转
43          DUP1 
44-48       PUSH4 0x70A08231 // 放入栈顶
49          EQ               // 比较input[:32]和0x70A08231，这里相等，所以将值设置为1
50-52       PUSH2 0x62       // 设置跳转的offset 
53          JUMPI            // 由于EQ相等，所以cond为1，所以跳转到0x62(十进制为98)处
98          JUMPDEST
99-101      PUSH2 0x7C
102-103     PUSH1 0x4 
104         DUP1
105         CALLDATASIZE     // 将input的长度放入栈顶
106         SUB              // pop长度，然后将栈顶元素赋值为长度-栈顶元素，可以理解为减去函数方法占用的4个字节
107         DUP2             // 将从栈顶数的第2个元素压入栈
108         ADD              // pop出栈顶元素，再将栈顶元素设置为其与栈顶元素相加的值
109         SWAP1            // 将栈顶元素与从栈顶数的第2(1+1)个元素交换
110-112     PUSH2 0x77
113         SWAP2 
114         SWAP1 
115-117     PUSH2 0x1CB
118         JUMP             // pop栈顶元素，然后跳转到值的index处（1cb=459）
459         JUMPDEST
460-461     PUSH1 0x0 
462-463     PUSH1 0x20 
464         DUP3 
465         DUP5 
466         SUB 
467         SLT              // pop栈顶元素，然后与栈顶元素比较，如果小于，则设置栈顶元素为1，否则为0，这里是false，则设置为0 
468         ISZERO           // 判断栈顶元素是否为0，为0则设置为1
469-471     PUSH2 0x1E1 
472         JUMPI            // offset=0x1E1，cond=1，所以跳转到 0x1e1
481         JUMPDEST 
482-483     PUSH1 0x0 
484-486     PUSH2 0x1EF 
487         DUP5 
488         DUP3 
489         DUP6 
490         ADD 
491-493     PUSH2 0x1A1 
494         JUMP             // 跳转到0x1A1 
417         JUMPDEST          
418-419     PUSH1 0x0 
420         DUP2 
421         CALLDATALOAD     // 加载input[4:]的数据到栈顶
。。。省略步骤，太多了直接来重点
313         SHA3             // 将memory[0]进行hash，获取数据库的key，实质上是用户的地址+私有变量的下标
314         SLOAD            // 通过statedb查找上面的hash后的key的值
145         RETURN           // 获取memory中保存的值，然后返回

```
调用一次查询余额的操作其实还蛮复杂的，会各种跳转，但关键操作是`SHA3`和`SLOAD`，首先是数据库中存储用户数据的key是如何来的。通过查看SHA3的方法，
可以看到Key是由用户address+变量下标得来的。所以当前的是key=hash(address+0)，所以从数据库（这个合约的）中搜索key对应的value值返回

### addBalance 合约方法的执行过程
现在看一下存在对合约操作的解释过程，这次我们只看重点
#### input
```
0xb5cef24a000000000000000000000000d80e810da222e282112f601f35040a24da7f770e
```
#### 执行过程
```
:index      :ops             :comment
。。。 省略其他操作
392         SHA3             // 生成查询的地址的key
397         SLOAD            // 根据key获取当前的值
669         ADD              // 将上面获取的值与设置的值相加
413         SSTORE           // 将相加的值写入数据库
173         STOP             // 停止返回
```
上链操作就会涉及到数据库操作`SSTORE`来更新状态

### transfer 合约方法的执行过程
上面的合约方法是涉及到合约全局变量的修改，我们来看一下特殊的，合约内部转账
#### input
```
0x1a6952300000000000000000000000005b38da6a701c568545dcfcb03fcb875f56beddc4
```
#### 执行过程
```
:index      :ops             :comment
。。。 省略多余操作
230         CALL             // 这个方法会触发调用interpreter.evm.Call，所以会触发transfer进行转账
97          STOP
```
当使用`transfer`时，实际上会调用`evm.Call`，相当于一个递归

### 合约嵌套
如果我们在一个合约里调用了另一个合约的方法，程序是如何执行的呢
#### 创建执行过程
会将使用的合约地址保存在数据库中
#### 调用执行过程
```
:index      :ops             :comment
。。。 省略多余操作
215         STATICCALL       // 此方法会调用evm.CALL，相当于新建一个contract对象，然后加载其CODE，然后运行
```
所以合约嵌套执行是通过类似CALL的操作码进行递归调用到evm.CALL的

## 关于内部转账
内部转账的实现可以通过以下三种方式

1. transfer (2300 gas, throws error)
2. send (2300 gas, returns bool)
3. call (forward all gas or set gas, returns bool)

本质上`transfer`和`send`会被编译器编译成`call`

## 参考

- [https://www.jianshu.com/p/230c6d805560](https://www.jianshu.com/p/230c6d805560)
- [https://solidity-by-example.org/sending-ether/](https://solidity-by-example.org/sending-ether/)
- [https://blog.csdn.net/u013288190/article/details/119760079](https://blog.csdn.net/u013288190/article/details/119760079)