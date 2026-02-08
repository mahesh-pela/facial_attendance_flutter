import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mydio.dart';

class UserProvider extends ChangeNotifier {
  Map<dynamic, dynamic> userData = {};
  Map<dynamic, dynamic> businessData = {};
  Map<dynamic, dynamic> roleData = {};
  Map<dynamic, dynamic> jwtData = {};
  var unreadNotifications;

  getConfig() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    try {
      var response = await (await MyDio().getDio())
          .get("/users/get-config")
          .timeout(Duration(seconds: 2));

      var userDataBox = await Hive.openBox("userData");
      // AllData = response.data['data'];
      await userDataBox.clear();
      await userDataBox.addAll([(response.data)]);

      await prefs.setString(
          'accessToken', response.data["accessToken"].toString());
    } on DioException catch (e) {
      print(e.response);
    }

    var userDataBox = await Hive.openBox("userData");
    List<dynamic> hiveMapData = userDataBox.values.toList();
    unreadNotifications = hiveMapData[0]["unreadNotifications"];

    userData = hiveMapData[0]["userData"];
    businessData = hiveMapData[0]["businessData"];
    jwtData = hiveMapData[0]["jwtdata"];
    roleData = hiveMapData[0]["jwtdata"]["role_data"];
    debugPrint("get config chalyoooooooooooo");

    List<dynamic> modulesEnabled = businessData["modules_enabled"];

    List<String> modulesEnabledString =
    modulesEnabled.map((data) => data.toString()).toList();

    await prefs.setStringList('modules_enabled', modulesEnabledString);

    notifyListeners();
  }
}
