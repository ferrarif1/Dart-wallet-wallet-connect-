import 'dart:convert';

import 'package:candide_mobile_app/config/network.dart';
import 'package:candide_mobile_app/controller/address_persistent_data.dart';
import 'package:candide_mobile_app/controller/settings_persistent_data.dart';
import 'package:candide_mobile_app/controller/token_info_storage.dart';
import 'package:candide_mobile_app/models/batch.dart';
import 'package:candide_mobile_app/models/fee_currency.dart';
import 'package:candide_mobile_app/models/gnosis_transaction.dart';
import 'package:candide_mobile_app/screens/home/components/transaction_review_sheet.dart';
import 'package:candide_mobile_app/screens/home/send/components/send_review_leading.dart';
import 'package:candide_mobile_app/screens/home/wallet_connect/components/wc_review_leading.dart';
import 'package:candide_mobile_app/screens/home/wallet_connect/components/wc_signature_reject_dialog.dart';
import 'package:candide_mobile_app/screens/home/wallet_connect/wc_session_request_sheet.dart';
import 'package:candide_mobile_app/services/bundler.dart';
import 'package:candide_mobile_app/utils/constants.dart';
import 'package:candide_mobile_app/utils/currency.dart';
import 'package:candide_mobile_app/utils/events.dart';
import 'package:candide_mobile_app/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:pausable_timer/pausable_timer.dart';
import 'package:short_uuids/short_uuids.dart';
import 'package:walletconnect_dart/walletconnect_dart.dart';
import 'package:web3dart/credentials.dart';
import 'package:web3dart/crypto.dart';

class WalletConnectController {
  late String sessionId;
  late WalletConnect connector;
  int _reconnectAttempts = 0;

  static int? _lastRestoredSessionsChainId;
  static late PausableTimer _connectivityTimer;
  static List<WalletConnectController> instances = [];

  // Save to Box called "wallet_connect" at "sessions({wallet_connect_version})({chainId})"
  static Future<void> persistAllSessions(int chainId) async {
    List<String> sessionsIds = [];
    for (final WalletConnectController controller in instances){
      sessionsIds.add(controller.sessionId);
    }
    await Hive.box("wallet_connect").put("sessions(1)($chainId)", sessionsIds);
  }

  static void restoreAllSessions(int chainId) async {
    _lastRestoredSessionsChainId ??= chainId;
    if (_lastRestoredSessionsChainId != chainId){
      for (final WalletConnectController controller in instances){
        await controller.connector.close(forceClose: true);
      }
      instances.clear();
    }
    _lastRestoredSessionsChainId = chainId;
    List sessions = Hive.box("wallet_connect").get("sessions(1)($chainId)") ?? []; // List<String>
    for (String sessionId in sessions){
      print("Restoring session $sessionId");
      await restoreSession(sessionId);
      await Future.delayed(const Duration(milliseconds: 250));
    }
  }

  static disconnectAllSessions() async {
    for (final WalletConnectController controller in instances){
      await controller.connector.killSession();
      controller.connector.close(forceClose: true);
    }
    instances.clear();
  }

  static startConnectivityAssuranceTimer(){
    _connectivityTimer = PausableTimer(const Duration(seconds: 40), _ensureConnectivity);
    _connectivityTimer.start();
  }

  static _ensureConnectivity() async {
    for (final WalletConnectController controller in instances){
      if (!controller.connector.bridgeConnected || controller._reconnectAttempts >= 3){
        controller.connector.reconnect();
        controller._reconnectAttempts = 0;
      }else{
        controller._reconnectAttempts++;
      }
    }
    _connectivityTimer..reset()..start();
  }

  static restoreSession(String sessionId) async {
    SessionStorage storage = _WalletConnectSecureStorage(storageKey: sessionId);
    WalletConnectSession? session = await storage.getSession();
    if (session == null) return;
    for (final WalletConnectController controller in instances){
      if (controller.sessionId == sessionId) return;
    }
    var controller = WalletConnectController();
    controller.connectSession(storage, session, sessionId);
  }

  WalletConnect connectSession(SessionStorage storage, WalletConnectSession session, String _sessionId){
    sessionId = _sessionId;
    connector = WalletConnect(
      sessionStorage: storage,
      session: session,
    );
    _initializeListeners();
    if (!connector.bridgeConnected){
      connector.reconnect();
    }
    if (!connector.connected){
      connector.connect(chainId: 5);
    }
    instances.add(this);
    return connector;
  }

  WalletConnect connect(String uri, String _sessionId){
    sessionId = _sessionId;
    connector = WalletConnect(
      uri: uri,
      sessionStorage: _WalletConnectSecureStorage(storageKey: sessionId)
    );
    _initializeListeners();
    instances.add(this);
    return connector;
  }

  Future<void> disconnect() async {
    await connector.killSession();
  }

  void _initializeListeners(){
    connector.on('connect', _handleConnect);
    connector.on('disconnect', _handleDisconnect);
    connector.on('session_request', _handleSessionRequest);
    connector.on('session_update', _handleSessionUpdate);
    connector.on('eth_sendTransaction', _ethSendTransaction);
    connector.on('eth_sign', _ethSign);
    connector.on('eth_signTypedData', _ethSignTypedData);
    connector.on('eth_signTypedData_v1', _ethSignTypedData);
    connector.on('eth_signTypedData_v2', _ethSignTypedData);
    connector.on('eth_signTypedData_v3', _ethSignTypedData);
    connector.on('eth_signTypedData_v4', _ethSignTypedData);
    connector.on('personal_sign', _ethPersonalSign);
  }

  void _handleConnect(Object? session) async {
    if (session is SessionStatus){
      await connector.sessionStorage?.store(connector.session);
      persistAllSessions(Networks.get(SettingsData.network)!.chainId.toInt());
    }
  }

  void _handleDisconnect(Object? session){
    connector.close();
    instances.remove(this);
    persistAllSessions(Networks.get(SettingsData.network)!.chainId.toInt());
    eventBus.fire(OnWalletConnectDisconnect());
  }

  void _handleSessionRequest(WCSessionRequest? payload){
    //print(payload);
    if (payload == null) return;
    if (payload.peerMeta == null) return;
    connector.session.clientMeta = payload.peerMeta;
    showBarModalBottomSheet(
      context: Get.context!,
      builder: (context) => SingleChildScrollView(
        controller: ModalScrollController.of(context),
        child: WCSessionRequestSheet(
          connector: connector,
        ),
      ),
    );
  }

  void _handleSessionUpdate(Object? payload){
    //print(payload.runtimeType);
    //print(payload);
    if (payload == null) return;
  }

  void _ethSendTransaction(JsonRpcRequest? payload) async {
    if (payload == null) return;
    //print(payload.toJson());
    var cancelLoad = Utils.showLoading();
    Batch wcBatch = Batch();
    String hexValue = "0x00";
    String gasLimit = "0x00";
    String data = "0x";
    if ((payload.params![0] as Map).containsKey("value")){
      hexValue = payload.params![0]["value"];
    }
    if ((payload.params![0] as Map).containsKey("gas")){
      gasLimit = payload.params![0]["gas"];
    }
    if ((payload.params![0] as Map).containsKey("data")){
      data = payload.params![0]["data"];
    }
    hexValue = hexValue.replaceAll("0x", "");
    gasLimit = gasLimit.replaceAll("0x", "");
    BigInt value = BigInt.parse(hexValue, radix: 16);
    BigInt gasValue = BigInt.parse(gasLimit, radix: 16);
    EthereumAddress toAddress = EthereumAddress.fromHex(payload.params![0]["to"]);
    var toCode = await Constants.client.getCode(toAddress);
    bool isTransfer = toCode.isEmpty || toAddress.hexEip55 == AddressData.wallet.walletAddress.hexEip55;
    //
    GnosisTransaction transaction = GnosisTransaction(
      id: "wc-$sessionId-${const ShortUuid().generate()}",
      to: toAddress,
      value: value,
      data: hexToBytes(data),
      type: GnosisTransactionType.execTransactionFromModule,
      suggestedGasLimit: gasValue,
    );
    wcBatch.transactions.add(transaction);
    //
    List<FeeToken>? feeCurrencies = await Bundler.fetchPaymasterFees();
    if (feeCurrencies == null){
      // todo handle network errors
      return;
    }else{
      await wcBatch.changeFeeCurrencies(feeCurrencies);
    }
    //
    cancelLoad();
    TransactionActivity transactionActivity = TransactionActivity(
      date: DateTime.now(),
      action: isTransfer ? "transfer" : "wc-transaction",
      title: isTransfer ? "Sent ETH" : "Contract Interaction",
      status: "pending",
      data: {"currency": "ETH", "amount": value.toString(), "to": toAddress.hexEip55},
    );
    //
    Map<String, String> tableEntriesData = {
      "To": payload.params![0]["to"],
    };
    if (value > BigInt.zero){
      tableEntriesData["Value"] = CurrencyUtils.formatCurrency(value, TokenInfoStorage.getTokenBySymbol("ETH")!, includeSymbol: true, formatSmallDecimals: true);
    }
    tableEntriesData["Network"] = SettingsData.network;
    //
    var executed = await showBarModalBottomSheet(
      context: Get.context!,
      builder: (context) {
        Get.put<ScrollController>(ModalScrollController.of(context)!, tag: "wc_transaction_review_modal");
        return TransactionReviewSheet(
          modalId: "wc_transaction_review_modal",
          leading: isTransfer ? SendReviewLeadingWidget(
            token: TokenInfoStorage.getTokenBySymbol("ETH")!,
            value: value,
            connector: connector,
          ) : WCReviewLeading(
            connector: connector,
            request: payload,
          ),
          /*leading: WCReviewLeading(
            connector: connector,
            request: payload,
          ),*/
          tableEntriesData: tableEntriesData,
          batch: wcBatch,
          transactionActivity: transactionActivity,
          showRejectButton: true,
        );
      },
    );
    if (executed == null || !executed){
      connector.rejectRequest(id: payload.id, errorMessage: "Rejected by user");
    }else{
      if (transactionActivity.hash != null){
        connector.approveRequest(id: payload.id, result: transactionActivity.hash!);
      }
    }
  }

  void _ethSignTypedData(JsonRpcRequest? payload){
    if (payload == null) return;
    String type = "typed-v4";
    if (payload.method != "eth_signTypedData"){
      RegExp regexp = RegExp(r"^eth_signTypedData_v([1,3,4])");
      type = "typed-v${regexp.allMatches(payload.method).last.group(1) ?? "4"}";
    }
    _showSignatureRequest(payload.id, type, payload.params?[1] ?? "");
  }

  void _ethSign(JsonRpcRequest? payload){
    if (payload == null) return;
    //print(payload.toJson());
    _showSignatureRequest(payload.id, "sign", payload.params?[1] ?? "");
  }

  void _ethPersonalSign(JsonRpcRequest? payload) {
    if (payload == null) return;
    //print(payload.toJson());
    _showSignatureRequest(payload.id, "personal", payload.params?[0] ?? "");
  }

  void _showSignatureRequest(int requestId, String type, String payload) async {
    await showDialog(
      context: Get.context!,
      builder: (_) => WCSignatureRejectDialog(connector: connector,),
      useRootNavigator: false,
    );
    connector.rejectRequest(id: requestId);
    // todo: re-enable when signing is ready
    /*showBarModalBottomSheet(
      context: Get.context!,
      builder: (context) {
        Get.put<ScrollController>(ModalScrollController.of(context)!, tag: "wc_signature_modal");
        return SignatureRequestSheet(
          requestId: requestId,
          connector: connector,
          signatureType: type,
          payload: payload,
        );
      },
    );*/
  }


}

class _WalletConnectSecureStorage implements SessionStorage {
  final String storageKey;
  final FlutterSecureStorage _storage;

  _WalletConnectSecureStorage({
    this.storageKey = 'wc_default_session',
    FlutterSecureStorage? storage,
  }) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<WalletConnectSession?> getSession() async {
    final json = await _storage.read(key: storageKey);
    if (json == null) {
      return null;
    }

    try {
      final data = jsonDecode(json);
      return WalletConnectSession.fromJson(data);
    } on FormatException {
      return null;
    }
  }

  @override
  Future store(WalletConnectSession session) async {
    await _storage.write(key: storageKey, value: jsonEncode(session.toJson()));
  }

  @override
  Future removeSession() async {
    await _storage.delete(key: storageKey);
  }
}