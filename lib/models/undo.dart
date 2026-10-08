/// 復原 / 重做堆疊（行為同 Qt 的 QUndoStack，Python 版用的就是它）。
///
/// push 會立刻執行指令的 redo；id 相同（且不是 −1）時嘗試和上一個指令合併。
library;

class UndoCommand {
  final String text;
  final int id; // −1 = 不合併
  final void Function() redo;
  final void Function() undo;

  /// 和下一個同 id 的指令合併；回傳 true 表示已合併（下一個指令丟掉）。
  final bool Function(UndoCommand next)? mergeWith;

  UndoCommand(this.text, {required this.redo, required this.undo, this.id = -1, this.mergeWith});
}

class UndoStack {
  final List<UndoCommand> _commands = [];
  int _index = 0;
  void Function()? onChanged;

  int get count => _commands.length;
  int get index => _index;
  bool get canUndo => _index > 0;
  bool get canRedo => _index < _commands.length;
  String get undoText => canUndo ? _commands[_index - 1].text : '';
  String get redoText => canRedo ? _commands[_index].text : '';

  /// 每一步的說明（操作紀錄）。
  List<String> get texts => [for (final c in _commands) c.text];

  /// 跳到第 idx 步之後的狀態（0 = 開始）：依序復原或重做。
  void setIndex(int idx) {
    idx = idx.clamp(0, _commands.length);
    while (_index > idx) {
      undo();
    }
    while (_index < idx) {
      redo();
    }
  }

  void push(UndoCommand cmd) {
    cmd.redo();
    if (_index < _commands.length) _commands.removeRange(_index, _commands.length);
    if (_index > 0 && cmd.id != -1) {
      final last = _commands[_index - 1];
      if (last.id == cmd.id && last.mergeWith != null && last.mergeWith!(cmd)) {
        onChanged?.call();
        return;
      }
    }
    _commands.add(cmd);
    _index = _commands.length;
    onChanged?.call();
  }

  void undo() {
    if (!canUndo) return;
    _index -= 1;
    _commands[_index].undo();
    onChanged?.call();
  }

  void redo() {
    if (!canRedo) return;
    _commands[_index].redo();
    _index += 1;
    onChanged?.call();
  }

  void clear() {
    _commands.clear();
    _index = 0;
    onChanged?.call();
  }
}
