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
   
   contract TestContract {
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
   608060405234801561001057600080fd5b5061038b806100206000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80631a6952301461004657806370a0823114610062578063b5cef24a14610092575b600080fd5b610060600480360381019061005b91906101f8565b6100ae565b005b61007c600480360381019061007791906101cb565b6100f9565b6040516100899190610234565b60405180910390f35b6100ac60048036038101906100a791906101f8565b610141565b005b8073ffffffffffffffffffffffffffffffffffffffff166108fc600a9081150290604051600060405180830381858888f193505050501580156100f5573d6000803e3d6000fd5b5050565b60008060008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020549050919050565b67016345785d8a00006000808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000206000828254610197919061024f565b9250508190555050565b6000813590506101b081610327565b92915050565b6000813590506101c58161033e565b92915050565b6000602082840312156101e1576101e0610322565b5b60006101ef848285016101a1565b91505092915050565b60006020828403121561020e5761020d610322565b5b600061021c848285016101b6565b91505092915050565b61022e816102e9565b82525050565b60006020820190506102496000830184610225565b92915050565b600061025a826102e9565b9150610265836102e9565b9250827fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0382111561029a576102996102f3565b5b828201905092915050565b60006102b0826102c9565b9050919050565b60006102c2826102c9565b9050919050565b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b6000819050919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b600080fd5b610330816102a5565b811461033b57600080fd5b50565b610347816102b7565b811461035257600080fd5b5056fea2646970667358221220560a7db3964c18024094ece0c5379f001e8716caeb3ab0613b67cd05f5a600f964736f6c63430008070033
   ```

   字节码可以根据`jumpTable`翻译成特定的操作（op），是由1个字节组成（有些是参数，不一定是1个字节），上面的字节码可以翻译成如下的操作码

   ```
   PUSH1 0x80 PUSH1 0x40 MSTORE CALLVALUE DUP1 ISZERO PUSH2 0x10 JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP PUSH2 0x38B DUP1 PUSH2 0x20 PUSH1 0x0 CODECOPY PUSH1 0x0 RETURN INVALID PUSH1 0x80 PUSH1 0x40 MSTORE CALLVALUE DUP1 ISZERO PUSH2 0x10 JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP PUSH1 0x4 CALLDATASIZE LT PUSH2 0x41 JUMPI PUSH1 0x0 CALLDATALOAD PUSH1 0xE0 SHR DUP1 PUSH4 0x1A695230 EQ PUSH2 0x46 JUMPI DUP1 PUSH4 0x70A08231 EQ PUSH2 0x62 JUMPI DUP1 PUSH4 0xB5CEF24A EQ PUSH2 0x92 JUMPI JUMPDEST PUSH1 0x0 DUP1 REVERT JUMPDEST PUSH2 0x60 PUSH1 0x4 DUP1 CALLDATASIZE SUB DUP2 ADD SWAP1 PUSH2 0x5B SWAP2 SWAP1 PUSH2 0x1F8 JUMP JUMPDEST PUSH2 0xAE JUMP JUMPDEST STOP JUMPDEST PUSH2 0x7C PUSH1 0x4 DUP1 CALLDATASIZE SUB DUP2 ADD SWAP1 PUSH2 0x77 SWAP2 SWAP1 PUSH2 0x1CB JUMP JUMPDEST PUSH2 0xF9 JUMP JUMPDEST PUSH1 0x40 MLOAD PUSH2 0x89 SWAP2 SWAP1 PUSH2 0x234 JUMP JUMPDEST PUSH1 0x40 MLOAD DUP1 SWAP2 SUB SWAP1 RETURN JUMPDEST PUSH2 0xAC PUSH1 0x4 DUP1 CALLDATASIZE SUB DUP2 ADD SWAP1 PUSH2 0xA7 SWAP2 SWAP1 PUSH2 0x1F8 JUMP JUMPDEST PUSH2 0x141 JUMP JUMPDEST STOP JUMPDEST DUP1 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND PUSH2 0x8FC PUSH1 0xA SWAP1 DUP2 ISZERO MUL SWAP1 PUSH1 0x40 MLOAD PUSH1 0x0 PUSH1 0x40 MLOAD DUP1 DUP4 SUB DUP2 DUP6 DUP9 DUP9 CALL SWAP4 POP POP POP POP ISZERO DUP1 ISZERO PUSH2 0xF5 JUMPI RETURNDATASIZE PUSH1 0x0 DUP1 RETURNDATACOPY RETURNDATASIZE PUSH1 0x0 REVERT JUMPDEST POP POP JUMP JUMPDEST PUSH1 0x0 DUP1 PUSH1 0x0 DUP4 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND DUP2 MSTORE PUSH1 0x20 ADD SWAP1 DUP2 MSTORE PUSH1 0x20 ADD PUSH1 0x0 KECCAK256 SLOAD SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH8 0x16345785D8A0000 PUSH1 0x0 DUP1 DUP4 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF AND DUP2 MSTORE PUSH1 0x20 ADD SWAP1 DUP2 MSTORE PUSH1 0x20 ADD PUSH1 0x0 KECCAK256 PUSH1 0x0 DUP3 DUP3 SLOAD PUSH2 0x197 SWAP2 SWAP1 PUSH2 0x24F JUMP JUMPDEST SWAP3 POP POP DUP2 SWAP1 SSTORE POP POP JUMP JUMPDEST PUSH1 0x0 DUP2 CALLDATALOAD SWAP1 POP PUSH2 0x1B0 DUP2 PUSH2 0x327 JUMP JUMPDEST SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 DUP2 CALLDATALOAD SWAP1 POP PUSH2 0x1C5 DUP2 PUSH2 0x33E JUMP JUMPDEST SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH1 0x20 DUP3 DUP5 SUB SLT ISZERO PUSH2 0x1E1 JUMPI PUSH2 0x1E0 PUSH2 0x322 JUMP JUMPDEST JUMPDEST PUSH1 0x0 PUSH2 0x1EF DUP5 DUP3 DUP6 ADD PUSH2 0x1A1 JUMP JUMPDEST SWAP2 POP POP SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH1 0x20 DUP3 DUP5 SUB SLT ISZERO PUSH2 0x20E JUMPI PUSH2 0x20D PUSH2 0x322 JUMP JUMPDEST JUMPDEST PUSH1 0x0 PUSH2 0x21C DUP5 DUP3 DUP6 ADD PUSH2 0x1B6 JUMP JUMPDEST SWAP2 POP POP SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH2 0x22E DUP2 PUSH2 0x2E9 JUMP JUMPDEST DUP3 MSTORE POP POP JUMP JUMPDEST PUSH1 0x0 PUSH1 0x20 DUP3 ADD SWAP1 POP PUSH2 0x249 PUSH1 0x0 DUP4 ADD DUP5 PUSH2 0x225 JUMP JUMPDEST SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH2 0x25A DUP3 PUSH2 0x2E9 JUMP JUMPDEST SWAP2 POP PUSH2 0x265 DUP4 PUSH2 0x2E9 JUMP JUMPDEST SWAP3 POP DUP3 PUSH32 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF SUB DUP3 GT ISZERO PUSH2 0x29A JUMPI PUSH2 0x299 PUSH2 0x2F3 JUMP JUMPDEST JUMPDEST DUP3 DUP3 ADD SWAP1 POP SWAP3 SWAP2 POP POP JUMP JUMPDEST PUSH1 0x0 PUSH2 0x2B0 DUP3 PUSH2 0x2C9 JUMP JUMPDEST SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH1 0x0 PUSH2 0x2C2 DUP3 PUSH2 0x2C9 JUMP JUMPDEST SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH1 0x0 PUSH20 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF DUP3 AND SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH1 0x0 DUP2 SWAP1 POP SWAP2 SWAP1 POP JUMP JUMPDEST PUSH32 0x4E487B7100000000000000000000000000000000000000000000000000000000 PUSH1 0x0 MSTORE PUSH1 0x11 PUSH1 0x4 MSTORE PUSH1 0x24 PUSH1 0x0 REVERT JUMPDEST PUSH1 0x0 DUP1 REVERT JUMPDEST PUSH2 0x330 DUP2 PUSH2 0x2A5 JUMP JUMPDEST DUP2 EQ PUSH2 0x33B JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP JUMP JUMPDEST PUSH2 0x347 DUP2 PUSH2 0x2B7 JUMP JUMPDEST DUP2 EQ PUSH2 0x352 JUMPI PUSH1 0x0 DUP1 REVERT JUMPDEST POP JUMP INVALID LOG2 PUSH5 0x6970667358 0x22 SLT KECCAK256 JUMP EXP PUSH30 0xB3964C18024094ECE0C5379F001E8716CAEB3AB0613B67CD05F5A600F964 PUSH20 0x6F6C634300080700330000000000000000000000
   ```

## 部署到测试链

1. 这里可以通过`Remix`进行部署，其中有3种方式
    1. JavaScript VM：js实现的EVM
    2. Injected Web3：浏览器的钱包插件
    3. Web3 Provider：直接通过web3建立连接，注意需要在启动时添加http和跨域参数`--http --http.corsdomain https://remix.ethereum.org`
2. 这里我DEBUG了一个ETH测试链，然后本地跑起来，再通过`Web3 Provider`的形式直连，这样就可以很方便的进行DEBUG了，具体流程可以谷歌

### 部署的运行逻辑

#### 首先看部署合约产生的交易

```
{
    "type":"0x2", // 这里的交易类型是DynamicFeeTxType，是EIP-1559的新协议使用的交易
    "nonce":"0x1",
    "gasPrice":null,
    "maxPriorityFeePerGas":"0x3b9aca00", // EIP-1559新增，计算手续费使用
    "maxFeePerGas":"0x77359400",				 // EIP-1559新增，计算手续费使用
    "gas":"0x3cb2a",
    "value":"0x0",											 // value是0
    "input":"0x608060405234801561001057600080fd5b5061038b806100206000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80631a6952301461004657806370a0823114610062578063b5cef24a14610092575b600080fd5b610060600480360381019061005b91906101f8565b6100ae565b005b61007c600480360381019061007791906101cb565b6100f9565b6040516100899190610234565b60405180910390f35b6100ac60048036038101906100a791906101f8565b610141565b005b8073ffffffffffffffffffffffffffffffffffffffff166108fc600a9081150290604051600060405180830381858888f193505050501580156100f5573d6000803e3d6000fd5b5050565b60008060008373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff168152602001908152602001600020549050919050565b67016345785d8a00006000808373ffffffffffffffffffffffffffffffffffffffff1673ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000206000828254610197919061024f565b9250508190555050565b6000813590506101b081610327565b92915050565b6000813590506101c58161033e565b92915050565b6000602082840312156101e1576101e0610322565b5b60006101ef848285016101a1565b91505092915050565b60006020828403121561020e5761020d610322565b5b600061021c848285016101b6565b91505092915050565b61022e816102e9565b82525050565b60006020820190506102496000830184610225565b92915050565b600061025a826102e9565b9150610265836102e9565b9250827fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0382111561029a576102996102f3565b5b828201905092915050565b60006102b0826102c9565b9050919050565b60006102c2826102c9565b9050919050565b600073ffffffffffffffffffffffffffffffffffffffff82169050919050565b6000819050919050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052601160045260246000fd5b600080fd5b610330816102a5565b811461033b57600080fd5b50565b610347816102b7565b811461035257600080fd5b5056fea2646970667358221220560a7db3964c18024094ece0c5379f001e8716caeb3ab0613b67cd05f5a600f964736f6c63430008070033", // input是合约的字节码
    "to":null, // to是nil
    "chainId":"0x7c8",
    "hash":"0xa3980499a36b7c0d16fc565a473179c7a48131aea586e67da24a67b4272e1330"
}
```

所以当to是nil时，是一个创建合约的交易

#### 代码运行

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
     // 返回运行结果
     return ret, address, contract.Gas, err
   }
   ```
#### 总结
1. 可以看到创建合约的交易是通过`to=nil`来标记的
2. 可以通过发送者的`address+nonce`计算合约地址
3. 合约最终会通过解释器运行

### 调用的运行逻辑
首先我们通过调用`balanceOf()`这个方法看一下合约调用逻辑
#### 调用合约的方法-不上链
在调用balanceOf之后，我们发现并没有在`EthAPIBackend.SendTx`处捕获到断点，查看`remix`状态，发现
调用的是eth_call这个api，通过检查注册的API，最终在`PublicBlockChainAPI.Call`找到了方法
##### PublicBlockChainAPI.Call
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
##### 方法和参数生成
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
跟复杂的拼接逻辑说明请看[官方文档](https://solidity-cn.readthedocs.io/zh/develop/abi-spec.html)

#### 调用合约的方法-上链
接下来我们调用`addBalance()`这个方法来进行上链数据的调用，看一下代码运行。
##### 交易结构
```

```
   

## 关于内部转账

内部转账的实现可以通过以下三种方式

1. transfer (2300 gas, throws error)
2. send (2300 gas, returns bool)
3. call (forward all gas or set gas, returns bool)

本质上`transfer`和`send`会被编译器编译成`call`

## 参考

- [https://www.jianshu.com/p/230c6d805560](https://www.jianshu.com/p/230c6d805560)
- [https://solidity-by-example.org/sending-ether/](https://solidity-by-example.org/sending-ether/)