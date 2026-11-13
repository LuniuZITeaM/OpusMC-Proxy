import 'package:flutter_test/flutter_test.dart';
import 'package:opus_mc_agent/protocol/state_registry.dart';

void main(){
  test('state comparison ignores only namespace and property order',(){
    verifyStateRegistry(['air','oak_log[axis=y,waterlogged=false]'],['minecraft:air','minecraft:oak_log[waterlogged=false,axis=y]']);
    expect(()=>verifyStateRegistry(['air'],['minecraft:stone']),throwsFormatException);
    expect(()=>verifyStateRegistry([],['minecraft:air']),throwsFormatException);
  });
}
