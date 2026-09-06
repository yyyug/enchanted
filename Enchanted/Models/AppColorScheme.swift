//
//  AppColorScheme.swift
//  Enchanted
//
//  Created by Augustinas Malinauskas on 11/12/2023.
//

import Foundation
import SwiftUI

enum AppColorScheme: String, Identifiable, CaseIterable {
    case light, dark, system
    
    var id: String {
        self.rawValue
    }
    
    var toString: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var localizedName: String {
        switch self {
        case .system:
            return NSLocalizedString("System", comment: "System appearance")
        case .light:
            return NSLocalizedString("Light", comment: "Light appearance")
        case .dark:
            return NSLocalizedString("Dark", comment: "Dark appearance")
        }
    }
    
    var toiOSFormat: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return ColorScheme.light
        case .dark:
            return ColorScheme.dark
        }
    }
}
