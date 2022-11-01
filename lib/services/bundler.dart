import 'dart:convert';
import 'dart:typed_data';

import 'package:candide_mobile_app/config/env.dart';
import 'package:candide_mobile_app/config/network.dart';
import 'package:candide_mobile_app/models/fee_currency.dart';
import 'package:candide_mobile_app/models/gas.dart';
import 'package:candide_mobile_app/models/relay_response.dart';
import 'package:dio/dio.dart';
import 'package:wallet_dart/wallet/user_operation.dart';
import 'package:web3dart/crypto.dart';
import 'package:web3dart/web3dart.dart';

class Bundler {

  static Future<List<UserOperation>> signUserOperations(Credentials signer, String network, List<UserOperation> userOperations) async{
    List<UserOperation> signedOperations = [];
    for (UserOperation operation in userOperations){
      UserOperation signedOperation = UserOperation.fromJson(operation.toJson());
      await signedOperation.sign(
        signer,
        Networks.get(network)!.chainId,
        overrideRequestId: await getRequestId(operation, network)
      );
      signedOperations.add(signedOperation);
    }
    return signedOperations;
  }

  static Future<RelayResponse?> relayUserOperations(List<UserOperation> userOperations, String network) async{
    try{
      var response = await Dio().post(
          "${Env.bundlerUri}/jsonrpc/bundler",
          data: jsonEncode({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_sendUserOperation",
            "params": [
              userOperations.map((e) => e.toJson()).toList()
            ]
          })
      );
      //
      //RelayResponse relayResponse = RelayResponse(status: response.data["status"], hash: response.data["hash"] ?? "");
      return RelayResponse(status: "SUCCESS", hash: ""); // todo real output
    } on DioError catch(e){
      print("Error occured ${e.type.toString()}");
      return null;
    }
  }

  static Future<List<FeeCurrency>?> fetchPaymasterFees() async {
    try{
      var response = await Dio().post("${Env.bundlerUri}/jsonrpc/paymaster",
        data: jsonEncode({
          "jsonrpc": "2.0",
          "id": 1,
          "method": "eth_paymaster_approved_tokens",
        })
      );
      //
      List<FeeCurrency> result = [];
      for (String tokenData in response.data['result']){
        var _tokenData = jsonDecode(tokenData.replaceAll("'", '"'));
        CurrencyMetadata? _currency = CurrencyMetadata.findByAddress(_tokenData["address"]);
        if (_currency == null) continue;
        result.add(FeeCurrency(currency: _currency, fee: _tokenData["price"].runtimeType == String ? BigInt.parse(_tokenData["price"]) : BigInt.from(_tokenData["price"])));
      }
      return result;
    } on DioError catch(e){
      print("Error occured ${e.type.toString()}");
      return null;
    }
  }

  static Future<List<GasEstimate>?> getOperationsGasFees(List<UserOperation> userOperations) async{
    try{
      var response = await Dio().post(
          "${Env.bundlerUri}/jsonrpc/bundler",
          data: jsonEncode({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getOperationsGasValues",
            "params": {
              "request": userOperations.map((e) => e.toJson()).toList(),
            }
          })
      );
      //
      List<GasEstimate> result = [];
      for (var op in response.data["result"]){
        GasEstimate estimate = GasEstimate(
          callGas: op["callGas"],
          preVerificationGas: op["preVerificationGas"],
          verificationGas: op["verificationGas"],
          maxPriorityFeePerGas: op["maxPriorityFeePerGas"],
          maxFeePerGas: op["maxFeePerGas"]
        );
        result.add(estimate);
      }

      return result;
    } on DioError catch(e){
      print("Error occured ${e.type.toString()}");
      return null;
    }
  }

  static Future<List<String>?> getPaymasterSignature(List<UserOperation> userOperations, String tokenAddress) async{
    try{
      var response = await Dio().post(
          "${Env.bundlerUri}/jsonrpc/paymaster",
          data: jsonEncode({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_paymaster",
            "params": {
              "request": userOperations.map((e) => e.toJson()).toList(),
              "token": tokenAddress,
            }
          })
      );
      //
      return (response.data["result"] as List<dynamic>).cast<String>();
    } on DioError catch(e){
      print("Error occured ${e.type.toString()}");
      return null;
    }
  }


  static Future<Uint8List?> getRequestId(UserOperation userOperation, String network, {bool returnHash=false}) async{
    try{
      var response = await Dio().post(
          "${Env.bundlerUri}/jsonrpc/bundler",
          data: jsonEncode({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "eth_getRequestId",
            "params": [
              userOperation.toJson()
            ]
          })
      );
      //
      return hexToBytes(response.data["result"]);
    } on DioError catch(e){
      print("Error occured ${e.type.toString()}");
      return null;
    }
  }
}