import '../main.dart';
import 'myDialog.dart';

void dioErrorManager(dynamic e, {String? additionalText}) {
  try {
    if (e.response?.data != null) {
      MyDialog(
          context: navigationKey.currentContext!,
          title: "Failed",
          message: e.response?.data["message"] ?? "Something went wrong",
          okText: "Ok");
    } else {
      MyDialog(
          context: navigationKey.currentContext!,
          title: "Connection failed!",
          message:
          "${additionalText ?? ""}Please check your internet connection & try again.",
          okText: "Ok");
    }
  } catch (e) {
    print('error $e');

    MyDialog(

        context: navigationKey.currentContext!,
        title: "Failed",
        message:
        "App has encountered an issue. Please contact development team.",
        okText: "Ok");
  }
}