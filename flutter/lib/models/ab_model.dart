import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/hbbs/hbbs.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:bot_toast/bot_toast.dart';
import 'package:http/http.dart' as http;

import '../common.dart';

final syncAbOption = 'sync-ab-with-recent-sessions';
bool shouldSyncAb() {
  return bind.mainGetLocalOption(key: syncAbOption).isNotEmpty;
}

final sortAbTagsOption = 'sync-ab-tags';
bool shouldSortTags() {
  return bind.mainGetLocalOption(key: sortAbTagsOption).isNotEmpty;
}

final filterAbTagOption = 'filter-ab-by-intersection';
bool filterAbTagByIntersection() {
  return bind.mainGetLocalOption(key: filterAbTagOption).isNotEmpty;
}

const _personalAddressBookName = "My address book";
const _legacyAddressBookName = "Legacy address book";

class AbModel {
  final addressbooks = Map<String, BaseAb>.fromEntries([]).obs;
  List<AbProfile> abProfiles = List.empty(growable: true);
  final RxString _currentName = ''.obs;
  RxString get currentName => _currentName;
  final _dummyAb = DummyAb();
  BaseAb get current => addressbooks[_currentName.value] ?? _dummyAb;

  RxList<Peer> get currentAbPeers => current.peers;
  RxList<String> get currentAbTags => current.tags;
  RxList<String> get selectedTags => current.selectedTags;

  RxBool get currentAbLoading => current.abLoading;
  RxString get currentAbPullError => current.pullError;
  RxString get currentAbPushError => current.pushError;
  bool get currentAbEmtpy => currentAbPeers.isEmpty && currentAbTags.isEmpty;
  String? _personalAbGuid;
  RxBool legacyMode = true.obs;

  final sortTags = shouldSortTags().obs;
  final filterByIntersection = filterAbTagByIntersection().obs;

  // licensedDevices is obtained from personal ab, shared ab restrict it in server
  var licensedDevices = 0;

  var _syncAllFromRecent = true;
  var _syncFromRecentLock = false;
  var _allInitialized = false;
  var _timerCounter = 0;
  var _cacheLoadOnceFlag = false;
  var _everPulledProfiles = false;
  // ignore: unused_field
  var _maxPeerOneAb = 0;

  WeakReference<FFI> parent;

  AbModel(this.parent) {
    addressbooks.clear();
    if (desktopType == DesktopType.main) {
      Timer.periodic(Duration(milliseconds: 500), (timer) async {
        if (_timerCounter++ % 6 == 0) {
          if (!gFFI.userModel.isLogin) return;
          if (!_allInitialized) return;
          _syncFromRecent();
        }
      });
    }
  }

  reset() async {
    print("reset ab model");
    _allInitialized = false;
    abProfiles.clear();
    addressbooks.clear();
    setCurrentName('');
    await bind.mainClearAb();
    licensedDevices = 0;
    _everPulledProfiles = false;
  }

// #region ab
  Future<void> pullAb({force = true, quiet = false}) async {
    await _pullAb(force: force, quiet: quiet);
    _refreshTab();
  }

  Future<void> _pullAb({force = true, quiet = false}) async {
    debugPrint("pullAb, force:$force, quiet:$quiet");
    if (!gFFI.userModel.isLogin) return;
    if (!force && _allInitialized) return;
    _allInitialized = false;
    try {
      // Get personal address book guid
      _personalAbGuid = null;
      await _getPersonalAbGuid();
      // Determine legacy mode based on whether _personalAbGuid is null
      legacyMode.value = _personalAbGuid == null;
      if (_personalAbGuid != null) {
        await _getAbSettings();
        List<AbProfile> tmpAbProfiles = List.empty(growable: true);
        tmpAbProfiles.add(AbProfile(_personalAbGuid!, _personalAddressBookName,
            gFFI.userModel.userName.value, null, ShareRule.read.value));
        // get all address book name
        await _getSharedAbProfiles(tmpAbProfiles);
        abProfiles = tmpAbProfiles;
        addressbooks.clear();
        for (int i = 0; i < abProfiles.length; i++) {
          AbProfile p = abProfiles[i];
          addressbooks[p.name] = Ab(p, p.guid == _personalAbGuid);
        }
      } else {
        // only legacy address book
        addressbooks.clear();
        addressbooks[_legacyAddressBookName] = LegacyAb();
      }
      // set current address book name
      if (!_everPulledProfiles) {
        _everPulledProfiles = true;
        final name = bind.getLocalFlutterOption(k: 'current-ab-name');
        if (addressbooks.containsKey(name)) {
          _currentName.value = name;
        }
      }
      if (!addressbooks.containsKey(_currentName.value)) {
        setCurrentName(_personalAddressBookName);
      }
      // pull shared ab data, current first
      await current.pullAb(force: force, quiet: quiet);
      addressbooks.forEach((key, value) async {
        if (key != current.name()) {
          return await value.pullAb(force: force, quiet: quiet);
        }
      });
      _saveCache();
      _allInitialized = true;
      _syncAllFromRecent = true;
    } catch (e) {
      debugPrint("pullAb error: $e");
    }
    // again in case of error happens
    if (!addressbooks.containsKey(_currentName.value)) {
      setCurrentName(_personalAddressBookName);
    }
  }

  Future<bool> _getAbSettings() async {
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/settings";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final resp = await http.post(Uri.parse(api), headers: headers);
      if (resp.statusCode == 404) {
        debugPrint("HTTP 404, api server doesn't support shared address book");
        return false;
      }
      Map<String, dynamic> json =
          _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
      if (json.containsKey('error')) {
        throw json['error'];
      }
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      _maxPeerOneAb = json['max_peer_one_ab'] ?? 0;
      return true;
    } catch (err) {
      debugPrint('get ab settings err: ${err.toString()}');
    }
    return false;
  }

  Future<bool> _getPersonalAbGuid() async {
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/personal";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final resp = await http.post(Uri.parse(api), headers: headers);
      if (resp.statusCode == 404) {
        debugPrint("HTTP 404, api server doesn't support shared address book");
        return false;
      }
      Map<String, dynamic> json =
          _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
      if (json.containsKey('error')) {
        throw json['error'];
      }
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      _personalAbGuid = json['guid'];
      return true;
    } catch (err) {
      debugPrint('get personal ab err: ${err.toString()}');
    }
    return false;
  }

  Future<bool> _getSharedAbProfiles(List<AbProfile> tmpSharedAbs) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/shared/profiles";
    try {
      var uri0 = Uri.parse(api);
      final pageSize = 100;
      var total = 0;
      int current = 0;
      do {
        current += 1;
        var uri = Uri(
            scheme: uri0.scheme,
            host: uri0.host,
            path: uri0.path,
            port: uri0.port,
            queryParameters: {
              'current': current.toString(),
              'pageSize': pageSize.toString(),
            });
        var headers = getHttpHeaders();
        headers['Content-Type'] = "application/json";
        final resp = await http.post(uri, headers: headers);
        Map<String, dynamic> json =
            _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final profile in data) {
                final u = AbProfile.fromJson(profile);
                int index = tmpSharedAbs.indexWhere((e) => e.name == u.name);
                if (index < 0) {
                  tmpSharedAbs.add(u);
                } else {
                  tmpSharedAbs[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      debugPrint('_getSharedAbProfiles err: ${err.toString()}');
    }
    return false;
  }

  Future<String> addSharedAb(String name, String note) async {
    try {
      if (addressbooks.containsKey(name)) {
        return '$name already exists';
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/shared/add";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      var v = {
        'name': name,
      };
      if (note.isNotEmpty) {
        v['note'] = note;
      }
      final body = jsonEncode(v);
      final resp =
          await http.post(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      return errMsg;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String> updateSharedAb(String guid, String name, String note) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/shared/update/profile";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      var v = {
        'guid': guid,
        'name': name,
      };
      if (note.isNotEmpty) {
        v['note'] = note;
      }
      final body = jsonEncode(v);
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      return errMsg;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String> deleteSharedAb(String name) async {
    try {
      final guid = abProfiles.firstWhereOrNull((e) => e.name == name)?.guid;
      if (guid == null) {
        return '$name not found';
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/shared";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode([guid]);
      final resp =
          await http.delete(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      return errMsg;
    } catch (e) {
      return e.toString();
    }
  }

// #endregion

// #region rule
  List<String> addressBooksCanWrite() {
    List<String> list = [];
    addressbooks.forEach((key, value) async {
      if (value.canWrite()) {
        list.add(key);
      }
    });
    return list;
  }

  Future<List<AbRulePayload>> getAllRules() async {
    try {
      List<AbRulePayload> res = [];
      final abGuid = current.sharedProfile()?.guid;
      if (abGuid == null) {
        return res;
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/rules";
      var uri0 = Uri.parse(api);
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final pageSize = 100;
      var total = 0;
      int currentPage = 0;
      do {
        currentPage += 1;
        var uri = Uri(
            scheme: uri0.scheme,
            host: uri0.host,
            path: uri0.path,
            port: uri0.port,
            queryParameters: {
              'current': currentPage.toString(),
              'pageSize': pageSize.toString(),
              'ab': abGuid,
            });
        final resp = await http.post(uri, headers: headers);
        Map<String, dynamic> json =
            _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
        if (resp.statusCode == 404) {
          debugPrint(
              "HTTP 404, api server doesn't support shared address book");
          return res;
        }
        if (json.containsKey('error')) {
          throw json['error'];
        }

        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final d in data) {
                final t = AbRulePayload.fromJson(d);
                res.add(t);
              }
            }
          }
        }
      } while (currentPage * pageSize < total);
      return res;
    } catch (err) {
      debugPrint('get all rules err: ${err.toString()}');
    }
    return [];
  }

  Future<String?> addRule(String name, int level, int rule) async {
    try {
      final abGuid = current.sharedProfile()?.guid;
      if (abGuid == null) {
        return "shared profile not found";
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/rule";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        'ab': abGuid,
        'name': name,
        'level': level,
        'rule': rule,
      });
      final resp =
          await http.post(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        return errMsg;
      }
      return null;
    } catch (err) {
      return err.toString();
    }
  }

  Future<String?> updateRule(String ruleGuid, int rule) async {
    try {
      final abGuid = current.sharedProfile()?.guid;
      if (abGuid == null) {
        return "shared profile not found";
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/rule";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        'guid': ruleGuid,
        'rule': rule,
      });
      final resp =
          await http.patch(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        return errMsg;
      }
      return null;
    } catch (err) {
      return err.toString();
    }
  }

  Future<String?> deleteRules(List<String> ruleGuids) async {
    try {
      final abGuid = current.sharedProfile()?.guid;
      if (abGuid == null) {
        return "shared profile not found";
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/rules";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode(ruleGuids);
      final resp =
          await http.delete(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        return errMsg;
      }
      return null;
    } catch (err) {
      return err.toString();
    }
  }

  Future<Map<String, List<String>>> getNamesTree() async {
    Map<String, List<String>> res = Map.fromEntries([]);
    try {
      final abGuid = current.sharedProfile()?.guid;
      if (abGuid == null) {
        return res;
      }
      final api = "${await bind.mainGetApiServer()}/api/ab/rule/tree/$abGuid";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final resp = await http.post(Uri.parse(api), headers: headers);
      if (resp.statusCode == 404) {
        debugPrint("HTTP 404, api server doesn't support shared address book");
        return res;
      }
      Map<String, dynamic> json =
          _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }
      json.forEach((key, value) {
        if (value is List) {
          res[key] = value.map((e) => e.toString()).toList();
        }
      });
      return res;
    } catch (err) {
      debugPrint('get name tree err: ${err.toString()}');
    }
    return res;
  }

// #endregion

// #region peer
  Future<String?> addIdToCurrent(
      String id, String alias, String password, List<dynamic> tags) async {
    if (currentAbPeers.where((element) => element.id == id).isNotEmpty) {
      return "$id already exists in address book $_currentName";
    }
    Map<String, dynamic> peer = {
      'id': id,
      'alias': alias,
      'tags': tags,
    };
    // avoid set existing password to empty
    if (password.isNotEmpty) {
      peer['password'] = password;
    }
    final ret = await addPeersTo([peer], _currentName.value);
    _timerCounter = 0;
    return ret;
  }

  // Use Map<String, dynamic> rather than Peer to distinguish between empty and null
  Future<String?> addPeersTo(
    List<Map<String, dynamic>> ps,
    String name,
  ) async {
    final ab = addressbooks[name];
    if (ab == null) {
      return 'no such addressbook: $name';
    }
    String? errMsg = await ab.addPeers(ps);
    await pullNonLegacyAfterChange(name: name);
    if (name == _currentName.value) {
      _refreshTab();
    }
    _syncAllFromRecent = true;
    _saveCache();
    return errMsg;
  }

  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) async {
    bool ret = await current.changeTagForPeers(ids, tags);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    _saveCache();
    return ret;
  }

  Future<bool> changeAlias({required String id, required String alias}) async {
    bool res = await current.changeAlias(id: id, alias: alias);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    _saveCache();
    return res;
  }

  Future<bool> changePersonalHashPassword(String id, String hash) async {
    var ret = false;
    final personalAb = addressbooks[_personalAddressBookName];
    if (personalAb != null) {
      ret = await personalAb.changePersonalHashPassword(id, hash);
      await pullNonLegacyAfterChange();
    } else {
      final legacyAb = addressbooks[_legacyAddressBookName];
      if (legacyAb != null) {
        ret = await legacyAb.changePersonalHashPassword(id, hash);
      }
    }
    _saveCache();
    return ret;
  }

  Future<bool> changeSharedPassword(
      String abName, String id, String password) async {
    final ret =
        await addressbooks[abName]?.changeSharedPassword(id, password) ?? false;
    await pullNonLegacyAfterChange();
    return ret;
  }

  Future<bool> deletePeers(List<String> ids) async {
    final ret = await current.deletePeers(ids);
    await pullNonLegacyAfterChange();
    currentAbPeers.refresh();
    _refreshTab();
    _saveCache();
    if (legacyMode.value && current.isPersonal()) {
      // non-legacy mode not add peers automatically
      Future.delayed(Duration(seconds: 2), () async {
        if (!shouldSyncAb()) return;
        var hasSynced = false;
        for (var id in ids) {
          if (await bind.mainPeerExists(id: id)) {
            hasSynced = true;
            break;
          }
        }
        if (hasSynced) {
          BotToast.showText(
              contentColor: Colors.lightBlue,
              text: translate('synced_peer_readded_tip'));
          _syncAllFromRecent = true;
        }
      });
    }
    return ret;
  }

// #endregion

// #region tags
  Future<bool> addTags(List<String> tagList) async {
    final ret = await current.addTags(tagList, {});
    await pullNonLegacyAfterChange();
    _saveCache();
    return ret;
  }

  Future<bool> renameTag(String oldTag, String newTag) async {
    final ret = await current.renameTag(oldTag, newTag);
    await pullNonLegacyAfterChange();
    selectedTags.value = selectedTags.map((e) {
      if (e == oldTag) {
        return newTag;
      } else {
        return e;
      }
    }).toList();
    _saveCache();
    return ret;
  }

  Future<bool> setTagColor(String tag, Color color) async {
    final ret = await current.setTagColor(tag, color);
    await pullNonLegacyAfterChange();
    _saveCache();
    return ret;
  }

  Future<bool> deleteTag(String tag) async {
    final ret = await current.deleteTag(tag);
    await pullNonLegacyAfterChange();
    _saveCache();
    return ret;
  }

// #endregion

// #region sync from recent
  Future<void> _syncFromRecent({bool push = true}) async {
    if (!_syncFromRecentLock) {
      _syncFromRecentLock = true;
      await _syncFromRecentWithoutLock(push: push);
      _syncFromRecentLock = false;
    }
  }

  Future<void> _syncFromRecentWithoutLock({bool push = true}) async {
    Future<List<Peer>> getRecentPeers() async {
      try {
        List<String> filteredPeerIDs;
        if (_syncAllFromRecent) {
          _syncAllFromRecent = false;
          filteredPeerIDs = [];
        } else {
          final new_stored_str = await bind.mainGetNewStoredPeers();
          if (new_stored_str.isEmpty) return [];
          filteredPeerIDs = (jsonDecode(new_stored_str) as List<dynamic>)
              .map((e) => e.toString())
              .toList();
          if (filteredPeerIDs.isEmpty) return [];
        }
        final loadStr = await bind.mainLoadRecentPeersForAb(
            filter: jsonEncode(filteredPeerIDs));
        if (loadStr.isEmpty) {
          return [];
        }
        List<dynamic> mapPeers = jsonDecode(loadStr);
        List<Peer> recents = List.empty(growable: true);
        for (var m in mapPeers) {
          if (m is Map<String, dynamic>) {
            recents.add(Peer.fromJson(m));
          }
        }
        return recents;
      } catch (e) {
        debugPrint('getRecentPeers: $e');
      }
      return [];
    }

    try {
      if (!shouldSyncAb()) return;
      final recents = await getRecentPeers();
      if (recents.isEmpty) return;
      debugPrint("sync from recent, len: ${recents.length}");
      addressbooks.forEach((key, value) async {
        if (value.canWrite()) {
          await value.syncFromRecent(recents);
        }
      });
    } catch (e) {
      debugPrint('_syncFromRecentWithoutLock: $e');
    }
  }

  void setShouldAsync(bool v) async {
    await bind.mainSetLocalOption(key: syncAbOption, value: v ? 'Y' : '');
    _syncAllFromRecent = true;
    _timerCounter = 0;
  }

// #endregion

// #region cache
  _saveCache() {
    try {
      var ab_entries = _serializeCache();
      Map<String, dynamic> m = <String, dynamic>{
        "access_token": bind.mainGetLocalOption(key: 'access_token'),
        "ab_entries": ab_entries,
      };
      bind.mainSaveAb(json: jsonEncode(m));
    } catch (e) {
      debugPrint('ab save:$e');
    }
  }

  List<dynamic> _serializeCache() {
    var res = [];
    addressbooks.forEach((key, value) {
      res.add({
        "guid": value.sharedProfile()?.guid ?? '',
        "name": key,
        "tags": value.tags,
        "peers": value.peers
            .map((e) => value.isPersonal()
                ? e.toPersonalAbUploadJson(true)
                : e.toSharedAbCacheJson())
            .toList(),
        "tag_colors": jsonEncode(value.tagColors)
      });
    });
    return res;
  }

  Future<void> loadCache() async {
    try {
      if (_cacheLoadOnceFlag || currentAbLoading.value) return;
      _cacheLoadOnceFlag = true;
      final access_token = bind.mainGetLocalOption(key: 'access_token');
      if (access_token.isEmpty) return;
      final cache = await bind.mainLoadAb();
      if (currentAbLoading.value) return;
      final data = jsonDecode(cache);
      if (data == null || data['access_token'] != access_token) return;
      _deserializeCache(data);
    } catch (e) {
      debugPrint("load ab cache: $e");
    }
  }

  _deserializeCache(dynamic data) {
    if (data == null) return;
    reset();
    final abEntries = data['ab_entries'];
    if (abEntries is List) {
      for (var i = 0; i < abEntries.length; i++) {
        var abEntry = abEntries[i];
        if (abEntry is Map<String, dynamic>) {
          var guid = abEntry['guid'];
          var name = abEntry['name'];
          final BaseAb ab;
          if (name == _legacyAddressBookName) {
            ab = LegacyAb();
          } else {
            if (name == null || guid == null) {
              continue;
            }
            ab = Ab(AbProfile(guid, name, '', '', ShareRule.read.value),
                name == _personalAddressBookName);
          }
          addressbooks[name] = ab;
          if (abEntry['tags'] is List) {
            ab.tags.value =
                (abEntry['tags'] as List).map((e) => e.toString()).toList();
          }
          if (abEntry['peers'] is List) {
            for (var peer in abEntry['peers']) {
              ab.peers.add(Peer.fromJson(peer));
            }
          }
          if (abEntry['tag_colors'] is String) {
            Map<String, dynamic> map = jsonDecode(abEntry['tag_colors']);
            ab.tagColors.value = Map<String, int>.from(map);
          }
        }
      }
    }
  }

// #endregion

// #region tools
  Peer? find(String id) {
    return currentAbPeers.firstWhereOrNull((e) => e.id == id);
  }

  bool idContainByCurrent(String id) {
    return currentAbPeers.where((element) => element.id == id).isNotEmpty;
  }

  void unsetSelectedTags() {
    selectedTags.clear();
  }

  List<dynamic> getPeerTags(String id) {
    final it = currentAbPeers.where((p0) => p0.id == id);
    if (it.isEmpty) {
      return [];
    } else {
      return it.first.tags;
    }
  }

  Color getCurrentAbTagColor(String tag) {
    int? colorValue = current.tagColors[tag];
    if (colorValue != null) {
      return Color(colorValue);
    }
    return str2color2(tag, existing: current.tagColors.values.toList());
  }

  List<String> addressBookNames() {
    return addressbooks.keys.toList();
  }

  void setCurrentName(String name) {
    if (addressbooks.containsKey(name)) {
      _currentName.value = name;
    } else {
      if (addressbooks.containsKey(_personalAddressBookName)) {
        _currentName.value = _personalAddressBookName;
      } else if (addressbooks.containsKey(_legacyAddressBookName)) {
        _currentName.value = _legacyAddressBookName;
      } else {
        _currentName.value = '';
      }
    }
    _refreshTab();
  }

  bool isCurrentAbFull(bool warn) {
    return current.isFull(warn);
  }

  void _refreshTab() {
    platformFFI.tryHandle({'name': LoadEvent.addressBook});
  }

  // should not call this function in a loop call stack
  Future<void> pullNonLegacyAfterChange({String? name}) async {
    if (name == null) {
      if (current.name() != _legacyAddressBookName) {
        return await current.pullAb(force: true, quiet: true);
      }
    } else if (name != _legacyAddressBookName) {
      final ab = addressbooks[name];
      if (ab != null) {
        return ab.pullAb(force: true, quiet: true);
      }
    }
  }

  List<String> idExistIn(String id) {
    List<String> v = [];
    addressbooks.forEach((key, value) {
      if (value.peers.any((e) => e.id == id)) {
        v.add(key);
      }
    });
    return v;
  }

  List<Peer> allPeers() {
    List<Peer> v = [];
    addressbooks.forEach((key, value) {
      v.addAll(value.peers.map((e) => Peer.copy(e)).toList());
    });
    return v;
  }

  String translatedName(String name) {
    if (name == _personalAddressBookName || name == _legacyAddressBookName) {
      return translate(name);
    } else {
      return name;
    }
  }

// #endregion
}

abstract class BaseAb {
  final peers = List<Peer>.empty(growable: true).obs;
  final RxList<String> tags = <String>[].obs;
  final RxMap<String, int> tagColors = Map<String, int>.fromEntries([]).obs;
  final selectedTags = List<String>.empty(growable: true).obs;

  final pullError = "".obs;
  final pushError = "".obs;
  final abLoading = false.obs;

  reset() {
    pullError.value = '';
    pushError.value = '';
    tags.clear();
    peers.clear();
  }

  String name();

  bool isPersonal() {
    return name() == _personalAddressBookName ||
        name() == _legacyAddressBookName;
  }

  Future<void> pullAb({force = true, quiet = false}) async {
    if (abLoading.value) return;
    if (!quiet) {
      abLoading.value = true;
      pullError.value = "";
    }
    final ret = pullAbImpl(force: force, quiet: quiet);
    abLoading.value = false;
    return ret;
  }

  Future<void> pullAbImpl({force = true, quiet = false});

  Future<String?> addPeers(List<Map<String, dynamic>> ps);
  removeHash(Map<String, dynamic> p) {
    p.remove('hash');
  }

  removePassword(Map<String, dynamic> p) {
    p.remove('password');
  }

  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags);

  Future<bool> changeAlias({required String id, required String alias});

  Future<bool> changePersonalHashPassword(String id, String hash);

  Future<bool> changeSharedPassword(String id, String password);

  Future<bool> deletePeers(List<String> ids);

  Future<bool> addTags(List<String> tagList, Map<String, int> tagColorMap);

  bool tagContainBy(String tag) {
    return tags.where((element) => element == tag).isNotEmpty;
  }

  Future<bool> renameTag(String oldTag, String newTag);

  Future<bool> setTagColor(String tag, Color color);

  Future<bool> deleteTag(String tag);

  bool isFull(bool warn) {
    bool res;
    res = gFFI.abModel.licensedDevices > 0 &&
        peers.length >= gFFI.abModel.licensedDevices;
    if (res && warn) {
      BotToast.showText(
          contentColor: Colors.red, text: translate("exceed_max_devices"));
    }
    return res;
  }

  AbProfile? sharedProfile();

  bool canWrite();

  bool fullControl();

  bool allowUpdateSettingsOrDelete();

  Future<void> syncFromRecent(List<Peer> recents);
}

class LegacyAb extends BaseAb {
  final sortTags = shouldSortTags().obs;
  final filterByIntersection = filterAbTagByIntersection().obs;
  bool get emtpy => peers.isEmpty && tags.isEmpty;

  LegacyAb();

  @override
  AbProfile? sharedProfile() {
    return null;
  }

  @override
  bool canWrite() {
    return true;
  }

  @override
  bool fullControl() {
    return true;
  }

  @override
  bool allowUpdateSettingsOrDelete() {
    return false;
  }

  @override
  String name() {
    return _legacyAddressBookName;
  }

  @override
  Future<void> pullAbImpl({force = true, quiet = false}) async {
    final api = "${await bind.mainGetApiServer()}/api/ab";
    int? statusCode;
    try {
      var authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      authHeaders['Accept-Encoding'] = "gzip";
      final resp = await http.get(Uri.parse(api), headers: authHeaders);
      statusCode = resp.statusCode;
      if (resp.body.toLowerCase() == "null") {
        // normal reply, emtpy ab return null
        tags.clear();
        tagColors.clear();
        peers.clear();
      } else if (resp.body.isNotEmpty) {
        Map<String, dynamic> json =
            _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
        if (json.containsKey('error')) {
          throw json['error'];
        } else if (json.containsKey('data')) {
          try {
            gFFI.abModel.licensedDevices = json['licensed_devices'];
            // ignore: empty_catches
          } catch (e) {}
          final data = jsonDecode(json['data']);
          if (data != null) {
            _deserialize(data);
          }
        }
      }
    } catch (err) {
      if (!quiet) {
        pullError.value =
            '${translate('pull_ab_failed_tip')}: ${translate(err.toString())}';
      }
    } finally {
      if (pullError.isNotEmpty) {
        if (statusCode == 401) {
          gFFI.userModel.reset(resetOther: true);
        }
      }
    }
  }

  Future<bool> pushAb(
      {bool toastIfFail = true, bool toastIfSucc = true}) async {
    debugPrint("pushAb: toastIfFail:$toastIfFail, toastIfSucc:$toastIfSucc");
    if (!gFFI.userModel.isLogin) return false;
    pushError.value = '';
    bool ret = false;
    try {
      //https: //stackoverflow.com/questions/68249333/flutter-getx-updating-item-in-children-list-is-not-reactive
      peers.refresh();
      final api = "${await bind.mainGetApiServer()}/api/ab";
      var authHeaders = getHttpHeaders();
      authHeaders['Content-Type'] = "application/json";
      final body = jsonEncode({"data": jsonEncode(_serialize())});
      http.Response resp;
      // support compression
      if (gFFI.abModel.licensedDevices > 0 && body.length > 1024) {
        authHeaders['Content-Encoding'] = "gzip";
        resp = await http.post(Uri.parse(api),
            headers: authHeaders, body: GZipCodec().encode(utf8.encode(body)));
      } else {
        resp =
            await http.post(Uri.parse(api), headers: authHeaders, body: body);
      }
      if (resp.statusCode == 200 &&
          (resp.body.isEmpty || resp.body.toLowerCase() == 'null')) {
        ret = true;
      } else {
        Map<String, dynamic> json =
            _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
        if (json.containsKey('error')) {
          throw json['error'];
        } else if (resp.statusCode == 200) {
          ret = true;
        } else {
          throw 'HTTP ${resp.statusCode}';
        }
      }
    } catch (e) {
      pushError.value =
          '${translate('push_ab_failed_tip')}: ${translate(e.toString())}';
    }

    if (!ret && toastIfFail) {
      BotToast.showText(contentColor: Colors.red, text: pushError.value);
    }
    if (ret && toastIfSucc) {
      showToast(translate('Successful'));
    }
    return ret;
  }

// #region Peer
  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    bool full = false;
    for (var p in ps) {
      if (!isFull(false)) {
        p.remove('password'); // legacy ab ignore password
        final index = peers.indexWhere((e) => e.id == p['id']);
        if (index >= 0) {
          _merge(Peer.fromJson(p), peers[index]);
          _mergePeerFromGroup(peers[index]);
        } else {
          peers.add(Peer.fromJson(p));
        }
      } else {
        full = true;
        break;
      }
    }
    if (!await pushAb()) {
      return "Failed to push to server";
    } else if (full) {
      return translate("exceed_max_devices");
    } else {
      return null;
    }
  }

  _mergePeerFromGroup(Peer p) {
    final g = gFFI.groupModel.peers.firstWhereOrNull((e) => p.id == e.id);
    if (g == null) return;
    if (p.username.isEmpty) {
      p.username = g.username;
    }
    if (p.hostname.isEmpty) {
      p.hostname = g.hostname;
    }
    if (p.platform.isEmpty) {
      p.platform = g.platform;
    }
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) async {
    peers.map((e) {
      if (ids.contains(e.id)) {
        e.tags = tags;
      }
    }).toList();
    return await pushAb();
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) async {
    final it = peers.where((element) => element.id == id);
    if (it.isEmpty) {
      return false;
    }
    it.first.alias = alias;
    return await pushAb();
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    // no need to implement
    return false;
  }

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {
    bool peerSyncEqual(Peer a, Peer b) {
      return a.hash == b.hash &&
          a.username == b.username &&
          a.platform == b.platform &&
          a.hostname == b.hostname &&
          a.alias == b.alias;
    }

    bool needSync = false;
    for (var i = 0; i < recents.length; i++) {
      var r = recents[i];
      var index = peers.indexWhere((e) => e.id == r.id);
      if (index < 0) {
        if (!isFull(false)) {
          peers.add(r);
          needSync = true;
        }
      } else {
        Peer old = Peer.copy(peers[index]);
        _merge(r, peers[index]);
        if (!peerSyncEqual(peers[index], old)) {
          needSync = true;
        }
      }
    }
    if (needSync) {
      await pushAb(toastIfSucc: false, toastIfFail: false);
      gFFI.abModel._refreshTab();
    }
    // Pull cannot be used for sync to avoid cyclic sync.
  }

  void _merge(Peer r, Peer p) {
    p.hash = r.hash.isEmpty ? p.hash : r.hash;
    p.username = r.username.isEmpty ? p.username : r.username;
    p.hostname = r.hostname.isEmpty ? p.hostname : r.hostname;
    p.platform = r.platform.isEmpty ? p.platform : r.platform;
    p.alias = p.alias.isEmpty ? r.alias : p.alias;
    p.forceAlwaysRelay = r.forceAlwaysRelay;
    p.rdpPort = r.rdpPort;
    p.rdpUsername = r.rdpUsername;
  }

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    bool changed = false;
    final it = peers.where((element) => element.id == id);
    if (it.isNotEmpty) {
      if (it.first.hash != hash) {
        it.first.hash = hash;
        changed = true;
      }
    }
    if (changed) {
      return await pushAb(toastIfSucc: false, toastIfFail: false);
    }
    return true;
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    peers.removeWhere((e) => ids.contains(e.id));
    return await pushAb();
  }
// #endregion

// #region Tag
  @override
  Future<bool> addTags(
      List<String> tagList, Map<String, int> tagColorMap) async {
    for (var e in tagList) {
      if (!tagContainBy(e)) {
        tags.add(e);
      }
    }
    return await pushAb();
  }

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    if (tags.contains(newTag)) {
      BotToast.showText(
          contentColor: Colors.red, text: 'Tag $newTag already exists');
      return false;
    }
    tags.value = tags.map((e) {
      if (e == oldTag) {
        return newTag;
      } else {
        return e;
      }
    }).toList();
    for (var peer in peers) {
      peer.tags = peer.tags.map((e) {
        if (e == oldTag) {
          return newTag;
        } else {
          return e;
        }
      }).toList();
    }
    int? oldColor = tagColors[oldTag];
    if (oldColor != null) {
      tagColors.remove(oldTag);
      tagColors.addAll({newTag: oldColor});
    }
    return await pushAb();
  }

  @override
  Future<bool> setTagColor(String tag, Color color) async {
    if (tags.contains(tag)) {
      tagColors[tag] = color.value;
    }
    return await pushAb();
  }

  @override
  Future<bool> deleteTag(String tag) async {
    gFFI.abModel.selectedTags.remove(tag);
    tags.removeWhere((element) => element == tag);
    tagColors.remove(tag);
    for (var peer in peers) {
      if (peer.tags.isEmpty) {
        continue;
      }
      if (peer.tags.contains(tag)) {
        peer.tags.remove(tag);
      }
    }
    return await pushAb();
  }

// #endregion

  Map<String, dynamic> _serialize() {
    final peersJsonData =
        peers.map((e) => e.toPersonalAbUploadJson(true)).toList();
    final tagColorJsonData = jsonEncode(tagColors);
    return {
      "tags": tags,
      "peers": peersJsonData,
      "tag_colors": tagColorJsonData
    };
  }

  _deserialize(dynamic data) {
    if (data == null) return;
    final oldOnlineIDs = peers.where((e) => e.online).map((e) => e.id).toList();
    tags.clear();
    tagColors.clear();
    peers.clear();
    if (data['tags'] is List) {
      tags.value = (data['tags'] as List).map((e) => e.toString()).toList();
    }
    if (data['peers'] is List) {
      for (final peer in data['peers']) {
        peers.add(Peer.fromJson(peer));
      }
    }
    if (isFull(false)) {
      peers.removeRange(gFFI.abModel.licensedDevices, peers.length);
    }
    // restore online
    peers
        .where((e) => oldOnlineIDs.contains(e.id))
        .map((e) => e.online = true)
        .toList();
    if (data['tag_colors'] is String) {
      Map<String, dynamic> map = jsonDecode(data['tag_colors']);
      tagColors.value = Map<String, int>.from(map);
    }
    // add color to tag
    final tagsWithoutColor =
        tags.toList().where((e) => !tagColors.containsKey(e)).toList();
    for (var t in tagsWithoutColor) {
      tagColors[t] = str2color2(t, existing: tagColors.values.toList()).value;
    }
  }
}

class Ab extends BaseAb {
  late final AbProfile profile;
  late final bool personal;
  final sortTags = shouldSortTags().obs;
  final filterByIntersection = filterAbTagByIntersection().obs;
  bool get emtpy => peers.isEmpty && tags.isEmpty;

  Ab(this.profile, this.personal);

  @override
  String name() {
    if (personal) {
      return _personalAddressBookName;
    } else {
      return profile.name;
    }
  }

  @override
  AbProfile? sharedProfile() {
    return profile;
  }

  bool creatorOrAdmin() {
    return profile.owner == gFFI.userModel.userName.value ||
        gFFI.userModel.isAdmin.value;
  }

  @override
  bool canWrite() {
    if (personal) {
      return true;
    } else {
      return profile.rule == ShareRule.readWrite.value ||
          profile.rule == ShareRule.fullControl.value;
    }
  }

  @override
  bool fullControl() {
    if (personal) {
      return true;
    } else {
      return profile.rule == ShareRule.fullControl.value;
    }
  }

  @override
  bool allowUpdateSettingsOrDelete() {
    if (personal) {
      return false;
    } else {
      return creatorOrAdmin();
    }
  }

  @override
  Future<void> pullAbImpl({force = true, quiet = false}) async {
    List<Peer> tmpPeers = [];
    await _fetchPeers(tmpPeers);
    peers.value = tmpPeers;
    List<AbTag> tmpTags = [];
    await _fetchTags(tmpTags);
    tags.value = tmpTags.map((e) => e.name).toList();
    Map<String, int> tmpTagColors = {};
    for (var t in tmpTags) {
      tmpTagColors[t.name] = t.color;
    }
    tagColors.value = tmpTagColors;
  }

  Future<bool> _fetchPeers(List<Peer> tmpPeers) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/peers";
    try {
      var uri0 = Uri.parse(api);
      final pageSize = 100;
      var total = 0;
      int current = 0;
      do {
        current += 1;
        var uri = Uri(
            scheme: uri0.scheme,
            host: uri0.host,
            path: uri0.path,
            port: uri0.port,
            queryParameters: {
              'current': current.toString(),
              'pageSize': pageSize.toString(),
              'ab': profile.guid,
            });
        var headers = getHttpHeaders();
        headers['Content-Type'] = "application/json";
        final resp = await http.post(uri, headers: headers);
        Map<String, dynamic> json =
            _jsonDecodeRespMap(utf8.decode(resp.bodyBytes), resp.statusCode);
        if (json.containsKey('error')) {
          throw json['error'];
        }
        if (resp.statusCode != 200) {
          throw 'HTTP ${resp.statusCode}';
        }
        if (json.containsKey('total')) {
          if (total == 0) total = json['total'];
          if (json.containsKey('data')) {
            final data = json['data'];
            if (data is List) {
              for (final profile in data) {
                final u = Peer.fromJson(profile);
                int index = tmpPeers.indexWhere((e) => e.id == u.id);
                if (index < 0) {
                  tmpPeers.add(u);
                } else {
                  tmpPeers[index] = u;
                }
              }
            }
          }
        }
      } while (current * pageSize < total);
      return true;
    } catch (err) {
      debugPrint('_fetchPeers err: ${err.toString()}');
    }
    return false;
  }

  Future<bool> _fetchTags(List<AbTag> tmpTags) async {
    final api = "${await bind.mainGetApiServer()}/api/ab/tags/${profile.guid}";
    try {
      var uri0 = Uri.parse(api);
      var uri = Uri(
        scheme: uri0.scheme,
        host: uri0.host,
        path: uri0.path,
        port: uri0.port,
      );
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final resp = await http.post(uri, headers: headers);
      List<dynamic> json =
          _jsonDecodeRespList(utf8.decode(resp.bodyBytes), resp.statusCode);
      if (resp.statusCode != 200) {
        throw 'HTTP ${resp.statusCode}';
      }

      for (final d in json) {
        final t = AbTag.fromJson(d);
        int index = tmpTags.indexWhere((e) => e.name == t.name);
        if (index < 0) {
          tmpTags.add(t);
        } else {
          tmpTags[index] = t;
        }
      }
      return true;
    } catch (err) {
      debugPrint('_fetchTags err: ${err.toString()}');
    }
    return false;
  }

// #region Peers
  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/add/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      for (var p in ps) {
        if (peers.firstWhereOrNull((e) => e.id == p['id']) != null) {
          continue;
        }
        if (isFull(false)) {
          return translate("exceed_max_devices");
        }
        if (personal) {
          removePassword(p);
        } else {
          removeHash(p);
        }
        String body = jsonEncode(p);
        final resp =
            await http.post(Uri.parse(api), headers: headers, body: body);
        final errMsg = _jsonDecodeActionResp(resp);
        if (errMsg.isNotEmpty) {
          return errMsg;
        }
      }
    } catch (err) {
      return err.toString();
    }
    return null;
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List<dynamic> tags) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      var ret = true;
      for (var id in ids) {
        final body = jsonEncode({"id": id, "tags": tags});
        final resp =
            await http.put(Uri.parse(api), headers: headers, body: body);
        final errMsg = _jsonDecodeActionResp(resp);
        if (errMsg.isNotEmpty) {
          BotToast.showText(contentColor: Colors.red, text: errMsg);
          ret = false;
          break;
        }
      }
      return ret;
    } catch (err) {
      debugPrint('changeTagForPeers err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({"id": id, "alias": alias});
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('changeAlias err: ${err.toString()}');
      return false;
    }
  }

  Future<bool> _setPassword(Object bodyContent) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode(bodyContent);
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('changeSharedPassword err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    if (!personal) return false;
    if (!peers.any((e) => e.id == id)) return false;
    return _setPassword({"id": id, "hash": hash});
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    if (personal) return false;
    return _setPassword({"id": id, "password": password});
  }

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {
    bool uiUpdate = false;
    bool peerSyncEqual(Peer a, Peer b) {
      return a.username == b.username &&
          a.platform == b.platform &&
          a.hostname == b.hostname;
    }

    Future<bool> syncOnePeer(Peer p, Peer r) async {
      p.username = r.username;
      p.hostname = r.hostname;
      p.platform = r.platform;
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        "id": p.id,
        "username": r.username,
        "hostname": r.hostname,
        "platform": r.platform
      });
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        debugPrint('syncOnePeer errMsg: $errMsg');
        return false;
      }
      uiUpdate = true;
      return true;
    }

    try {
      /* Remove this because IDs that are not on the server can't be synced, then sync will happen every startup.
      // Try add new peers to personal ab
      if (personal) {
        for (var r in recents) {
          if (peers.length < gFFI.abModel._maxPeerOneAb) {
            if (!peers.any((e) => e.id == r.id)) {
              var err = await addPeers([r.toPersonalAbUploadJson(true)]);
              if (err == null) {
                peers.add(r);
                uiUpdate = true;
              }
            }
          }
        }
      }
      */
      final syncPeers = peers.where((p0) => p0.sameServer != true);
      for (var p in syncPeers) {
        Peer? r = recents.firstWhereOrNull((e) => e.id == p.id);
        if (r != null) {
          if (!peerSyncEqual(p, r)) {
            await syncOnePeer(p, r);
          }
        }
      }
      // Pull cannot be used for sync to avoid cyclic sync.
      if (uiUpdate && gFFI.abModel.currentName.value == profile.name) {
        peers.refresh();
      }
    } catch (err) {
      debugPrint('syncFromRecent err: ${err.toString()}');
    }
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/peer/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode(ids);
      final resp =
          await http.delete(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('deletePeers err: ${err.toString()}');
      return false;
    }
  }
// #endregion

// #region Tags
  @override
  Future<bool> addTags(
      List<String> tagList, Map<String, int> tagColorMap) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/tag/add/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      for (var t in tagList) {
        final body = jsonEncode({
          "name": t,
          "color": tagColorMap[t] ??
              str2color2(t, existing: tagColors.values.toList()).value,
        });
        final resp =
            await http.post(Uri.parse(api), headers: headers, body: body);
        final errMsg = _jsonDecodeActionResp(resp);
        if (errMsg.isNotEmpty) {
          BotToast.showText(contentColor: Colors.red, text: errMsg);
          return false;
        }
      }
      return true;
    } catch (err) {
      debugPrint('addTags err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    if (tags.contains(newTag)) {
      BotToast.showText(
          contentColor: Colors.red, text: 'Tag $newTag already exists');
      return false;
    }
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/tag/rename/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        "old": oldTag,
        "new": newTag,
      });
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('renameTag err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> setTagColor(String tag, Color color) async {
    try {
      final api =
          "${await bind.mainGetApiServer()}/api/ab/tag/update/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode({
        "name": tag,
        "color": color.value,
      });
      final resp = await http.put(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('setTagColor err: ${err.toString()}');
      return false;
    }
  }

  @override
  Future<bool> deleteTag(String tag) async {
    try {
      final api = "${await bind.mainGetApiServer()}/api/ab/tag/${profile.guid}";
      var headers = getHttpHeaders();
      headers['Content-Type'] = "application/json";
      final body = jsonEncode([tag]);
      final resp =
          await http.delete(Uri.parse(api), headers: headers, body: body);
      final errMsg = _jsonDecodeActionResp(resp);
      if (errMsg.isNotEmpty) {
        BotToast.showText(contentColor: Colors.red, text: errMsg);
        return false;
      }
      return true;
    } catch (err) {
      debugPrint('deleteTag err: ${err.toString()}');
      return false;
    }
  }

// #endregion
}

// DummyAb is for current ab is null
class DummyAb extends BaseAb {
  @override
  Future<String?> addPeers(List<Map<String, dynamic>> ps) async {
    return "Unreachable";
  }

  @override
  Future<bool> addTags(
      List<String> tagList, Map<String, int> tagColorMap) async {
    return false;
  }

  @override
  bool canWrite() {
    return false;
  }

  @override
  bool fullControl() {
    return false;
  }

  @override
  bool allowUpdateSettingsOrDelete() {
    return false;
  }

  @override
  Future<bool> changeAlias({required String id, required String alias}) async {
    return false;
  }

  @override
  Future<bool> changePersonalHashPassword(String id, String hash) async {
    return false;
  }

  @override
  Future<bool> changeSharedPassword(String id, String password) async {
    return false;
  }

  @override
  Future<bool> changeTagForPeers(List<String> ids, List tags) async {
    return false;
  }

  @override
  Future<bool> deletePeers(List<String> ids) async {
    return false;
  }

  @override
  Future<bool> deleteTag(String tag) async {
    return false;
  }

  @override
  String name() {
    return "Unreachable";
  }

  @override
  Future<void> pullAbImpl({force = true, quiet = false}) async {}

  @override
  Future<bool> renameTag(String oldTag, String newTag) async {
    return false;
  }

  @override
  Future<bool> setTagColor(String tag, Color color) async {
    return false;
  }

  @override
  AbProfile? sharedProfile() {
    return null;
  }

  @override
  Future<void> syncFromRecent(List<Peer> recents) async {}
}

Map<String, dynamic> _jsonDecodeRespMap(String body, int statusCode) {
  try {
    Map<String, dynamic> json = jsonDecode(body);
    return json;
  } catch (e) {
    final err = body.isNotEmpty && body.length < 128 ? body : e.toString();
    if (statusCode != 200) {
      throw 'HTTP $statusCode, $err';
    }
    throw err;
  }
}

List<dynamic> _jsonDecodeRespList(String body, int statusCode) {
  try {
    List<dynamic> json = jsonDecode(body);
    return json;
  } catch (e) {
    final err = body.isNotEmpty && body.length < 128 ? body : e.toString();
    if (statusCode != 200) {
      throw 'HTTP $statusCode, $err';
    }
    throw err;
  }
}

String _jsonDecodeActionResp(http.Response resp) {
  var errMsg = '';
  if (resp.statusCode == 200 && resp.body.isEmpty) {
    // ok
  } else {
    try {
      errMsg = jsonDecode(resp.body)['error'].toString();
    } catch (_) {}
    if (errMsg.isEmpty) {
      if (resp.statusCode != 200) {
        errMsg = 'HTTP ${resp.statusCode}';
      }
      if (resp.body.isNotEmpty) {
        if (errMsg.isNotEmpty) {
          errMsg += ', ';
        }
        errMsg += resp.body;
      }
      if (errMsg.isEmpty) {
        errMsg = "unknown error";
      }
    }
  }
  return errMsg;
}
