import AppKit
import SwiftUI

@main
struct Control24App: App {
    @StateObject private var store: LabStore
    init() {
        do {let model=try LabStore();_store=StateObject(wrappedValue:model)}
        catch {fatalError("Control|24 Lab could not start: \(error.localizedDescription)")}
    }
    var body: some Scene {
        WindowGroup("Control|24 Lab") {
            RootView().environmentObject(store).preferredColorScheme(.dark)
                .frame(minWidth:1100,minHeight:720)
                .onAppear { store.hardwareProxy.connectManaged() }
        }
        .defaultSize(width:1450,height:940)
        .commands {
            CommandGroup(replacing:.newItem) {}
            CommandMenu("Surface") {
                Button("Disable OSC output") {if store.armed {store.toggleOutput()}}
                    .keyboardShortcut(".",modifiers:[.command,.shift])
                Button("Export event log…") {store.exportLog()}.keyboardShortcut("e",modifiers:[.command,.shift])
                Divider()
                ForEach(Array(store.profiles.enumerated()),id:\.element.id) {index,profile in
                    Button(profile.name) {store.switchProfile(profile.id)}
                        .keyboardShortcut(KeyEquivalent(Character(String(index+1))),modifiers:[.control,.option])
                }
            }
        }
    }
}
