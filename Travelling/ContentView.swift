//
//  ContentView.swift
//  Travelling
//
//  Created by Dmytro on 2026-11-16.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Image("Space")
                .resizable()
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300)
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
