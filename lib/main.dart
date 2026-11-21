import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_windows/webview_windows.dart';

bool get isWindowsDesktop => !kIsWeb && Platform.isWindows;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MagnetHunterApp());
}

class MagnetHunterApp extends StatelessWidget {
  const MagnetHunterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MagnetHunter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0C0F14),
        colorScheme: const ColorScheme.dark(primary: Colors.tealAccent, secondary: Colors.amber),
      ),
      home: const HunterHomeScreen(),
    );
  }
}

class MagnetItem {
  final String hash;
  final String magnetUrl;
  final String titulo;
  final String qualidade;
  final String audio;
  final String origemUrl;

  MagnetItem({
    required this.hash,
    required this.magnetUrl,
    required this.titulo,
    required this.qualidade,
    required this.audio,
    required this.origemUrl,
  });

  Map<String, dynamic> toJson() => {
        'hash': hash,
        'magnetUrl': magnetUrl,
        'titulo': titulo,
        'qualidade': qualidade,
        'audio': audio,
        'origemUrl': origemUrl,
      };

  factory MagnetItem.fromJson(Map<String, dynamic> j) => MagnetItem(
        hash: j['hash'] ?? '',
        magnetUrl: j['magnetUrl'] ?? '',
        titulo: j['titulo'] ?? 'Magnet Link',
        qualidade: j['qualidade'] ?? '1080p',
        audio: j['audio'] ?? 'Dublado',
        origemUrl: j['origemUrl'] ?? '',
      );
}

class BrowserTab {
  final String id;
  String title;
  String currentUrl;
  bool isLoading;
  WebViewController? mobileCtrl;
  WebviewController? winCtrl;
  bool winReady;

  BrowserTab({
    required this.id,
    required this.title,
    required this.currentUrl,
    this.mobileCtrl,
    this.winCtrl,
    this.winReady = false,
    this.isLoading = false,
  });
}

class HunterHomeScreen extends StatefulWidget {
  const HunterHomeScreen({super.key});

  @override
  State<HunterHomeScreen> createState() => _HunterHomeScreenState();
}

class _HunterHomeScreenState extends State<HunterHomeScreen> {
  int _abaInferior = 0;
  final List<BrowserTab> _tabs = [];
  int _activeTabIndex = 0;
  final _urlCtrl = TextEditingController();

  final Map<String, MagnetItem> _captados = {};
  final Set<String> _selecionados = {};
  bool _autoScan = true;

  @override
  void initState() {
    super.initState();
    _carregarSalvos();
    _abrirNovaAba('https://duckduckgo.com', selecionar: true);
  }

  Future<void> _carregarSalvos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('hunter_captados') ?? '[]';
    try {
      final list = jsonDecode(raw) as List;
      setState(() {
        for (final e in list) {
          final item = MagnetItem.fromJson(Map<String, dynamic>.from(e as Map));
          if (item.hash.isNotEmpty) {
            _captados[item.hash] = item;
            _selecionados.add(item.hash);
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _salvarCaptados() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('hunter_captados', jsonEncode(_captados.values.map((e) => e.toJson()).toList()));
  }

  String _extrairHash(String magnet) {
    final m = RegExp(r'btih:([a-zA-Z0-9]{32,40})', caseSensitive: false).firstMatch(magnet);
    return (m?.group(1) ?? magnet.hashCode.toString()).toLowerCase();
  }

  MagnetItem _parseMagnet(String magnet, String origem) {
    final clean = magnet.trim().replaceAll('&amp;', '&');
    final hash = _extrairHash(clean);
    String titulo = '';
    final dn = Uri.tryParse(clean)?.queryParameters['dn'] ?? '';
    if (dn.isNotEmpty) {
      titulo = Uri.decodeComponent(dn.replaceAll('+', ' ')).replaceAll(RegExp(r'[._]+'), ' ').trim();
    }
    if (titulo.isEmpty) titulo = 'Torrent_${hash.substring(0, hash.length >= 8 ? 8 : hash.length)}';
    final low = '$titulo $clean'.toLowerCase();
    final qual = (low.contains('2160') || low.contains('4k'))
        ? '4K'
        : (low.contains('720') ? '720p' : '1080p');
    final audio = low.contains('dual')
        ? 'Dual Áudio'
        : ((low.contains('leg') && !low.contains('dub')) ? 'Legendado' : 'Dublado');

    return MagnetItem(
      hash: hash,
      magnetUrl: clean,
      titulo: titulo,
      qualidade: qual,
      audio: audio,
      origemUrl: origem,
    );
  }

  int _adicionarMagnets(Iterable<String> rawMagnets, String origem, {bool notificar = true}) {
    int novos = 0;
    for (final raw in rawMagnets) {
      final clean = raw.trim().replaceAll('&amp;', '&');
      if (!clean.toLowerCase().startsWith('magnet:?')) continue;
      final item = _parseMagnet(clean, origem);
      if (!_captados.containsKey(item.hash)) {
        _captados[item.hash] = item;
        _selecionados.add(item.hash);
        novos++;
      }
    }
    if (novos > 0) {
      setState(() {});
      _salvarCaptados();
      if (notificar && mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            backgroundColor: Colors.teal.shade800,
            content: Text('+$novos magnet(s) captado(s)! Total: ${_captados.length}'),
          ),
        );
      }
    }
    return novos;
  }

  Future<void> _escanearPaginaAtual({bool manual = false}) async {
    if (_tabs.isEmpty) return;
    final tab = _tabs[_activeTabIndex];
    try {
      const js = '''
      (function() {
        var found = new Set();
        var re = /magnet:\\?xt=urn:btih:[a-zA-Z0-9]+[^\\s"'<>\\\\]*/gi;
        var html = document.documentElement ? document.documentElement.innerHTML : '';
        var text = document.body ? document.body.innerText : '';
        var m1 = html.match(re) || [];
        var m2 = text.match(re) || [];
        m1.forEach(function(x){ found.add(x); });
        m2.forEach(function(x){ found.add(x); });
        document.querySelectorAll('a[href^="magnet:"], [data-magnet], [data-url^="magnet:"]').forEach(function(el){
          var h = el.getAttribute('href') || el.getAttribute('data-magnet') || el.getAttribute('data-url');
          if (h && h.toLowerCase().startsWith('magnet:')) found.add(h);
        });
        return JSON.stringify(Array.from(found));
      })();
      ''';
      dynamic res;
      if (isWindowsDesktop && tab.winCtrl != null && tab.winReady) {
        res = await tab.winCtrl!.executeScript(js);
      } else if (tab.mobileCtrl != null) {
        res = await tab.mobileCtrl!.runJavaScriptReturningResult(js);
      } else {
        return;
      }
      String rawStr = res.toString();
      if (rawStr.startsWith('"') && rawStr.endsWith('"')) {
        rawStr = jsonDecode(rawStr).toString();
      }
      final list = List<String>.from(jsonDecode(rawStr) as List);
      final novos = _adicionarMagnets(list, tab.currentUrl, notificar: true);
      if (manual && novos == 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(list.isEmpty ? 'Nenhum magnet encontrado nesta página.' : 'Todos os ${list.length} magnets desta página já foram captados.')),
        );
      }
    } catch (_) {}
  }

  Future<void> _initWindowsTab(BrowserTab tab, String urlInicial) async {
    final ctrl = WebviewController();
    tab.winCtrl = ctrl;
    try {
      await ctrl.initialize();
      await ctrl.setBackgroundColor(const Color(0xFF0C0F14));
      await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.sameWindow);
      ctrl.url.listen((url) {
        if (!mounted) return;
        if (url.toLowerCase().startsWith('magnet:?')) {
          _adicionarMagnets([url], tab.currentUrl);
          return;
        }
        setState(() {
          tab.currentUrl = url;
          if (_tabs.isNotEmpty && _tabs[_activeTabIndex].id == tab.id) {
            _urlCtrl.text = url;
          }
        });
      });
      ctrl.title.listen((t) {
        if (!mounted) return;
        if (t.trim().isNotEmpty) {
          setState(() => tab.title = t.trim());
        }
      });
      ctrl.loadingState.listen((state) async {
        if (!mounted) return;
        final loading = state == LoadingState.loading;
        setState(() => tab.isLoading = loading);
        if (!loading && _autoScan) {
          await Future.delayed(const Duration(milliseconds: 600));
          _escanearPaginaAtual();
        }
      });
      await ctrl.loadUrl(urlInicial);
      if (mounted) {
        setState(() => tab.winReady = true);
      }
    } catch (_) {}
  }

  void _abrirNovaAba(String urlInicial, {bool selecionar = true}) {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    late BrowserTab tab;

    if (isWindowsDesktop) {
      tab = BrowserTab(
        id: id,
        title: 'Nova Aba',
        currentUrl: urlInicial,
        isLoading: true,
      );
      setState(() {
        _tabs.add(tab);
        if (selecionar) {
          _activeTabIndex = _tabs.length - 1;
          _urlCtrl.text = urlInicial;
        }
      });
      _initWindowsTab(tab, urlInicial);
      return;
    }

    final ctrl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              tab.isLoading = true;
              tab.currentUrl = url;
              if (_tabs.isNotEmpty && _tabs[_activeTabIndex].id == tab.id) {
                _urlCtrl.text = url;
              }
            });
          },
          onPageFinished: (url) async {
            if (!mounted) return;
            final t = await tab.mobileCtrl?.getTitle();
            setState(() {
              tab.isLoading = false;
              tab.currentUrl = url;
              if (t != null && t.trim().isNotEmpty) tab.title = t.trim();
              if (_tabs.isNotEmpty && _tabs[_activeTabIndex].id == tab.id) {
                _urlCtrl.text = url;
              }
            });
            await tab.mobileCtrl?.runJavaScript('''
              document.querySelectorAll('a[target="_blank"]').forEach(function(a) {
                a.removeAttribute('target');
              });
            ''');
            if (_autoScan) {
              await Future.delayed(const Duration(milliseconds: 600));
              _escanearPaginaAtual();
            }
          },
          onNavigationRequest: (req) {
            final u = req.url;
            if (u.toLowerCase().startsWith('magnet:?')) {
              _adicionarMagnets([u], tab.currentUrl);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(urlInicial));

    tab = BrowserTab(
      id: id,
      title: 'Nova Aba',
      currentUrl: urlInicial,
      mobileCtrl: ctrl,
      isLoading: true,
    );

    setState(() {
      _tabs.add(tab);
      if (selecionar) {
        _activeTabIndex = _tabs.length - 1;
        _urlCtrl.text = urlInicial;
      }
    });
  }

  void _fecharAba(int index) {
    if (_tabs.length == 1) {
      _navegarNaAba(_tabs[0], 'https://duckduckgo.com');
      return;
    }
    final removida = _tabs[index];
    removida.winCtrl?.dispose();
    setState(() {
      _tabs.removeAt(index);
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      }
      _urlCtrl.text = _tabs[_activeTabIndex].currentUrl;
    });
  }

  void _navegarNaAba(BrowserTab tab, String url) {
    if (isWindowsDesktop) {
      tab.winCtrl?.loadUrl(url);
    } else {
      tab.mobileCtrl?.loadRequest(Uri.parse(url));
    }
  }

  void _navegarPara(String entrada) {
    var q = entrada.trim();
    if (q.isEmpty || _tabs.isEmpty) return;
    if (q.toLowerCase().startsWith('magnet:?')) {
      _adicionarMagnets([q], 'Colado manualmente');
      return;
    }
    if (!q.startsWith('http://') && !q.startsWith('https://')) {
      if (q.contains('.') && !q.contains(' ')) {
        q = 'https://$q';
      } else {
        q = 'https://duckduckgo.com/?q=${Uri.encodeComponent(q)}';
      }
    }
    _navegarNaAba(_tabs[_activeTabIndex], q);
    FocusScope.of(context).unfocus();
  }

  Directory? _resolverPastaDownloads() {
    if (isWindowsDesktop) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      if (home.isNotEmpty) {
        return Directory('$home\\Downloads');
      }
      return null;
    }
    return Directory('/storage/emulated/0/Download');
  }

  Future<void> _exportarArquivoTxt() async {
    final itens = _captados.values.where((e) => _selecionados.contains(e.hash)).toList();
    if (itens.isEmpty) return;
    final conteudo = itens.map((e) => e.magnetUrl).join('\n');
    try {
      final now = DateTime.now();
      final nome = 'magnets_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.txt';
      final dir = _resolverPastaDownloads();
      if (dir != null && await dir.exists()) {
        final sep = isWindowsDesktop ? '\\' : '/';
        final file = File('${dir.path}$sep$nome');
        await file.writeAsString(conteudo);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.green,
              content: Text('Salvo em Downloads/$nome (${itens.length} links)!'),
            ),
          );
        }
        return;
      }
    } catch (_) {}
    await Clipboard.setData(ClipboardData(text: conteudo));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${itens.length} magnets copiados para a área de transferência!')),
      );
    }
  }

  Future<void> _colarTextoParaExtrair() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Extrair Magnets de Texto/HTML'),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'Cole aqui qualquer texto, código-fonte ou lista bagunçada contendo magnet:?...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () {
              final matches = RegExp(r'''magnet:\?xt=urn:btih:[a-zA-Z0-9]+[^\s"'<>\\]*''', caseSensitive: false).allMatches(ctrl.text);
              final encontrados = matches.map((m) => m.group(0) ?? '').where((s) => s.isNotEmpty).toList();
              Navigator.pop(ctx);
              final n = _adicionarMagnets(encontrados, 'Texto colado', notificar: false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('$n novo(s) magnet(s) extraído(s)!')),
              );
            },
            child: const Text('Extrair'),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView(BrowserTab tab) {
    if (isWindowsDesktop) {
      if (!tab.winReady || tab.winCtrl == null) {
        return const Center(child: CircularProgressIndicator(color: Colors.tealAccent));
      }
      return Webview(tab.winCtrl!);
    }
    return WebViewWidget(controller: tab.mobileCtrl!);
  }

  @override
  Widget build(BuildContext context) {
    final currentTab = _tabs.isNotEmpty ? _tabs[_activeTabIndex] : null;
    final listaCaptados = _captados.values.toList().reversed.toList();

    return Scaffold(
      appBar: _abaInferior == 0 && currentTab != null
          ? AppBar(
              titleSpacing: 4,
              title: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 17),
                    onPressed: () async {
                      if (isWindowsDesktop) {
                        await currentTab.winCtrl?.goBack();
                      } else if (await currentTab.mobileCtrl?.canGoBack() ?? false) {
                        await currentTab.mobileCtrl?.goBack();
                      }
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios, size: 17),
                    onPressed: () async {
                      if (isWindowsDesktop) {
                        await currentTab.winCtrl?.goForward();
                      } else if (await currentTab.mobileCtrl?.canGoForward() ?? false) {
                        await currentTab.mobileCtrl?.goForward();
                      }
                    },
                  ),
                  Expanded(
                    child: TextField(
                      controller: _urlCtrl,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _navegarPara,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'URL ou pesquisar...',
                        filled: true,
                        fillColor: const Color(0xFF181D27),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                        suffixIcon: IconButton(
                          icon: Icon(currentTab.isLoading ? Icons.close : Icons.refresh, size: 18),
                          onPressed: () {
                            if (isWindowsDesktop) {
                              currentTab.winCtrl?.reload();
                            } else {
                              currentTab.mobileCtrl?.reload();
                            }
                          },
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Captar Magnets desta página',
                    icon: const Icon(Icons.radar, color: Colors.tealAccent),
                    onPressed: () => _escanearPaginaAtual(manual: true),
                  ),
                ],
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(40),
                child: SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          itemCount: _tabs.length,
                          itemBuilder: (_, idx) {
                            final t = _tabs[idx];
                            final ativo = idx == _activeTabIndex;
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  _activeTabIndex = idx;
                                  _urlCtrl.text = t.currentUrl;
                                });
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  color: ativo ? Colors.tealAccent.withValues(alpha: 0.2) : const Color(0xFF171B24),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: ativo ? Colors.tealAccent : Colors.white12),
                                ),
                                child: Row(
                                  children: [
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 130),
                                      child: Text(
                                        t.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 11.5, color: ativo ? Colors.tealAccent : Colors.white70),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      onTap: () => _fecharAba(idx),
                                      child: const Icon(Icons.close, size: 14, color: Colors.white54),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      IconButton(
                        tooltip: 'Nova Aba',
                        icon: const Icon(Icons.add_box_outlined, color: Colors.amber, size: 20),
                        onPressed: () => _abrirNovaAba('https://duckduckgo.com'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : AppBar(
              title: Text('Magnets Captados (${_captados.length})'),
              actions: [
                IconButton(
                  tooltip: 'Colar texto para extrair',
                  icon: const Icon(Icons.content_paste_search, color: Colors.amber),
                  onPressed: _colarTextoParaExtrair,
                ),
                if (_captados.isNotEmpty)
                  IconButton(
                    tooltip: 'Limpar tudo',
                    icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
                    onPressed: () {
                      setState(() {
                        _captados.clear();
                        _selecionados.clear();
                      });
                      _salvarCaptados();
                    },
                  ),
              ],
            ),
      body: IndexedStack(
        index: _abaInferior,
        children: [
          currentTab == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  children: [
                    if (currentTab.isLoading) const LinearProgressIndicator(minHeight: 2, color: Colors.tealAccent),
                    Expanded(child: _buildWebView(currentTab)),
                  ],
                ),
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Checkbox(
                          value: listaCaptados.isNotEmpty && _selecionados.length == listaCaptados.length,
                          activeColor: Colors.tealAccent,
                          checkColor: Colors.black,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selecionados.addAll(_captados.keys);
                              } else {
                                _selecionados.clear();
                              }
                            });
                          },
                        ),
                        Expanded(
                          child: Text('${_selecionados.length}/${listaCaptados.length} selecionado(s)', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.amber, foregroundColor: Colors.black),
                          onPressed: _selecionados.isEmpty ? null : _exportarArquivoTxt,
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('Salvar .TXT', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 6),
                        OutlinedButton.icon(
                          onPressed: _selecionados.isEmpty
                              ? null
                              : () async {
                                  final txt = _captados.values.where((e) => _selecionados.contains(e.hash)).map((e) => e.magnetUrl).join('\n');
                                  await Clipboard.setData(ClipboardData(text: txt));
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lista copiada!')));
                                  }
                                },
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('Copiar'),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      activeThumbColor: Colors.tealAccent,
                      title: const Text('Radar automático ao navegar nas páginas', style: TextStyle(fontSize: 12.5)),
                      value: _autoScan,
                      onChanged: (v) => setState(() => _autoScan = v),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: listaCaptados.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Nenhum magnet captado ainda.\nNavegue em qualquer site público na aba "Navegador" ou toque no ícone de colar texto acima.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white60),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        itemCount: listaCaptados.length,
                        itemBuilder: (_, i) {
                          final it = listaCaptados[i];
                          final sel = _selecionados.contains(it.hash);
                          return Card(
                            child: CheckboxListTile(
                              value: sel,
                              activeColor: Colors.tealAccent,
                              checkColor: Colors.black,
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selecionados.add(it.hash);
                                  } else {
                                    _selecionados.remove(it.hash);
                                  }
                                });
                              },
                              title: Text(it.titulo, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5)),
                              subtitle: Text('${it.qualidade} • ${it.audio}\n${it.magnetUrl}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white60)),
                              secondary: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () {
                                  setState(() {
                                    _captados.remove(it.hash);
                                    _selecionados.remove(it.hash);
                                  });
                                  _salvarCaptados();
                                },
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _abaInferior,
        selectedItemColor: Colors.tealAccent,
        onTap: (i) => setState(() => _abaInferior = i),
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.public), label: 'Navegador (${_tabs.length})'),
          BottomNavigationBarItem(icon: const Icon(Icons.link), label: 'Captados (${_captados.length})'),
        ],
      ),
    );
  }
}
