import 'dart:convert';

import 'package:biometric_storage/biometric_storage.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:candide_mobile_app/config/theme.dart';
import 'package:candide_mobile_app/controller/address_persistent_data.dart';
import 'package:candide_mobile_app/controller/security.dart';
import 'package:candide_mobile_app/controller/settings_persistent_data.dart';
import 'package:candide_mobile_app/models/recovery_request.dart';
import 'package:candide_mobile_app/screens/home/guardians/magic_email_sheet.dart';
import 'package:candide_mobile_app/screens/home/home_screen.dart';
import 'package:candide_mobile_app/screens/onboard/recovery/recovery_progress_dialog.dart';
import 'package:candide_mobile_app/screens/onboard/recovery/recovery_request_page.dart';
import 'package:candide_mobile_app/screens/onboard/recovery/recovery_wallet_sheet.dart';
import 'package:candide_mobile_app/utils/guardian_helpers.dart';
import 'package:candide_mobile_app/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:modal_bottom_sheet/modal_bottom_sheet.dart';
import 'package:wallet_dart/contracts/wallet.dart';
import 'package:wallet_dart/wallet/wallet_helpers.dart';
import 'package:wallet_dart/wallet/wallet_instance.dart';
import 'package:web3dart/web3dart.dart';

class RecoverSheet extends StatefulWidget {
  const RecoverSheet({Key? key}) : super(key: key);

  @override
  State<RecoverSheet> createState() => _RecoverSheetState();
}

class _RecoverSheetState extends State<RecoverSheet> {


  navigateToHome(){
    AddressData.loadExplorerJson(null);
    SettingsData.loadFromJson(null);
    Get.off(const HomeScreen());
  }

  setupRecoveryWallet(String address, String password, bool biometricsEnabled, String method) async {
    var cancelLoad = Utils.showLoading();
    // check if wallet has any guardians before proceeding
    int guardiansCount = 0;
    try {
      guardiansCount = (await CWallet.customInterface(EthereumAddress.fromHex(address)).getGuardiansCount()).toInt();
    } catch (exception) {
      cancelLoad();
      Utils.showError(title: "Error", message: "Lost wallet address is not a smart contract wallet");
      return;
    }
    if (guardiansCount == 0){
      cancelLoad();
      Utils.showError(title: "Error", message: "This wallet does not have any guardians, unfortunately this means this wallet cannot be recovered, contact us to learn more");
      return;
    }
    //
    if (biometricsEnabled){
      try {
        final store = await BiometricStorage().getStorage('auth_data');
        await store.write(password);
        await Hive.box("settings").put("biometrics_enabled", true);
      } on AuthException catch(_) {
        BotToast.showText(
            text: "User cancelled biometrics auth, please try again",
            contentColor: Colors.red.shade900,
            align: Alignment.topCenter,
            borderRadius: BorderRadius.circular(20)
        );
        return;
      }
    }else{
      await Hive.box("settings").put("biometrics_enabled", false);
    }
    var salt = base64Encode(Utils.randomBytes(16, secure: true));
    WalletInstance wallet = await WalletHelpers.createRecovery(address, password, salt);
    print(wallet.toJson());
    await Hive.box("wallet").put("recovered", jsonEncode(wallet.toJson()));
    cancelLoad();
    Get.back();
    //
    if (method == "email-recovery"){
      showEmailRecoveryDialog(wallet);
    }else if (method == "social-recovery"){
      startRecoveryRequest(wallet);
    }
    //
  }

  void startRecoveryRequest(WalletInstance wallet) async {
    var cancelLoad = Utils.showLoading();
    RecoveryRequest? request = await SecurityGateway.create(wallet.walletAddress.hex, wallet.initOwner, SettingsData.network);
    if (request == null){
      cancelLoad();
      if (SecurityGateway.latestErrorCode == 429){
        Utils.showError(title: "Error", message: "A recovery request was created for this wallet in the past hour, please wait some time and try again");
      }else{
        Utils.showError(title: "Error", message: "Error occurred while trying to create a recovery request, please try again later or contact us");
      }
      return;
    }
    cancelLoad();
    AddressData.storeRecoveryRequest(request.id);
    Get.off(RecoveryRequestPage(request: request));
  }

  void showEmailRecoveryDialog(WalletInstance wallet){
    showBarModalBottomSheet(
      context: Get.context!,
      builder: (context) => SingleChildScrollView(
        controller: ModalScrollController.of(context),
        child: MagicEmailSheet(
          onProceed: (String email) async {
            bool result = await GuardiansHelper.setupMagicLinkRecovery(email, wallet.walletAddress.hex, wallet.initOwner);
            if (result){
              bool success = await Get.dialog(RecoveryProgressDialog(
                walletAddress: wallet.walletAddress.hex,
                expectedOwner: wallet.initOwner,
              ));
              if (success){
                AddressData.wallet = wallet;
                await Hive.box("wallet").put("main", jsonEncode(wallet.toJson()));
                navigateToHome();
              }
            }
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 35,),
        Text("Select a recovery method", style: TextStyle(fontFamily: AppThemes.fonts.gilroyBold, fontSize: 20),),
        const SizedBox(height: 10,),
        _RecoveryMethodCard(
          type: "Email recovery",
          logo: SizedBox(
              width: 25,
              height: 25,
              child: SvgPicture.asset("assets/images/magic_link.svg")
          ),
          onPress: () async{
            Get.back();
            await showBarModalBottomSheet(
              context: context,
              builder: (context) {
                Get.put<ScrollController>(ModalScrollController.of(context)!, tag: "recovery_wallet_modal");
                return RecoveryWalletSheet(
                  method: "email-recovery",
                  onNext: setupRecoveryWallet
                );
              },
            );
          },
        ),
        _RecoveryMethodCard(
          type: "Family and friends",
          logo: SizedBox(
              width: 25,
              height: 25,
              child: SvgPicture.asset("assets/images/friends.svg")
          ),
          onPress: () async {
            await showBarModalBottomSheet(
              context: context,
              builder: (context) {
                Get.put<ScrollController>(ModalScrollController.of(context)!, tag: "recovery_wallet_modal");
                return RecoveryWalletSheet(
                  method: "social-recovery",
                  onNext: setupRecoveryWallet
                );
              },
            );
          },
        ),
        const SizedBox(height: 35,),
      ],
    );
  }
}

class _RecoveryMethodCard extends StatelessWidget { // todo move to components
  final String type;
  final Widget logo;
  final VoidCallback onPress;
  const _RecoveryMethodCard({Key? key, required this.type, required this.logo, required this.onPress}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10),
      child: Card(
        elevation: 3,
        child: InkWell(
          onTap: onPress,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 15),
            child: Row(
              children: [
                const SizedBox(width: 5,),
                logo,
                const SizedBox(width: 15,),
                Text(type.capitalize!, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),),
                const SizedBox(width: 5,),
                const Spacer(),
                const Icon(Icons.arrow_forward_ios_rounded),
                const SizedBox(width: 5,),
              ],
            ),
          ),
        ),
      ),
    );
  }
}