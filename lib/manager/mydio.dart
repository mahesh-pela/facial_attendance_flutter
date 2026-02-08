import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MyDio {
  Future<Dio> getDio() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? accessToken = prefs.getString("accessToken");
    String? apiURL = prefs.getString("apiURL");

    BaseOptions options = BaseOptions(
        baseUrl: "${apiURL}/api/v1" ?? "",
        connectTimeout: Duration(seconds: 10),
        headers: {"Authorization": "Bearer ${accessToken}"});

    Dio dio = Dio(options);
    return dio;
  }
}
