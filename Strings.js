.pragma library

// Texts of this panel: written in Portuguese, English for every other locale.
var english = Qt.locale().name.indexOf("pt") !== 0
var en = {
 "Desembaraçando fios": "Untangling wires",
 "Transmitindo vikings": "Streaming vikings",
 "Pareando mistérios": "Pairing mysteries",
 "Reunindo fones": "Herding headsets",
 "Domando rádios": "Taming radios",
 "Convocando caixas de som": "Summoning speakers",
 "Laçando codecs": "Wrangling codecs",
 "Polindo pacotes": "Polishing packets",
 "Sem adaptador": "No adapter",
 "Desligado": "Turned Off",
 "Desligar o Bluetooth": "Turn Bluetooth off",
 "Ligar o Bluetooth": "Turn Bluetooth on",
 "CONHECIDOS": "PAIRED",
 "ENCONTRADOS": "AVAILABLE",
 "CONECTADOS": "CONNECTED",
 "Nenhum adaptador Bluetooth": "No Bluetooth adapter",
 "Ligue o Bluetooth para procurar aparelhos": "Turn Bluetooth on to scan",
 "Procurando aparelhos…": "Scanning for devices…",
 "Desconectar": "Disconnect",
 "Parear": "Pair",
 "Conectar": "Connect",
 "Esquecendo…": "Forgetting…",
 "Desconectando…": "Disconnecting…",
 "Conectando…": "Connecting…",
 "Aparelho": "Device",
 "Esquecer": "Forget",
 "Conectado": "Connected",
 "Bateria ": "Battery ",
 "Fechar ajustes do iPhone": "Close iPhone settings",
 "Ajustes do iPhone (Tether)": "iPhone settings (Tether)"
}

function T(s) { return english && en[s] !== undefined ? en[s] : s }
