import 'package:ethora_sdk_flutter/ethora_sdk_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes base URL by appending /v1 when missing', () {
    const config = ChatComponentConfig(baseUrl: 'https://api.ethoradev.com');
    expect(config.normalizedBaseUrl, 'https://api.ethoradev.com/v1');
  });

  test('keeps /v1 when already present', () {
    const config = ChatComponentConfig(baseUrl: 'https://api.ethoradev.com/v1');
    expect(config.normalizedBaseUrl, 'https://api.ethoradev.com/v1');
  });
}
