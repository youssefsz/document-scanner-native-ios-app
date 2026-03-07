//
//  ContentView.swift
//  document-scaner
//
//  Created by Youssef Dhibi on 7/3/2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        LibraryView()
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentLibrary.preview)
}
