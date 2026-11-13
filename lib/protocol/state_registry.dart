/// Bridge state IDs may be copied only when its registry matches vanilla 26.2.
/// Property ordering and the default namespace have no semantic significance.
String canonicalState(String state) {
  final bracket=state.indexOf('[');
  final name=(bracket<0?state:state.substring(0,bracket)).replaceFirst(RegExp(r'^minecraft:'),'');
  if(bracket<0) return name;
  if(!state.endsWith(']')) throw const FormatException('Malformed block state');
  final properties=state.substring(bracket+1,state.length-1).split(',')..sort();
  return '$name[${properties.join(',')}]';
}

void verifyStateRegistry(List<dynamic> bridge,List<dynamic> vanilla) {
  if(bridge.length!=vanilla.length) throw const FormatException('房间方块注册表不是 26.2，无法直接代理');
  for(var i=0;i<vanilla.length;i++) {
    if(bridge[i] is! String || canonicalState(bridge[i] as String)!=canonicalState(vanilla[i] as String)) {
      throw FormatException('房间方块注册表与 26.2 不匹配（状态 $i）');
    }
  }
}
