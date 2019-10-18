//
//  OctopusGameCoordinator.swift
//  OctopusKit
//
//  Created by ShinryakuTako@invadingoctopus.io on 2017/11/07.
//  Copyright © 2019 Invading Octopus. Licensed under Apache License v2.0 (see LICENSE.txt)
//

import Combine
import GameplayKit

/// The primary coordinator for the various states a game may be in.
///
/// This is a "controller" in the MVC sense; use this class to coordinate game states and scenes, and to manage global objects that must be shared across scenes, such as the game world, player data, and network connections etc.
///
/// You may use `OctopusGameCoordinator` as-is or subclass it to add any global/top-level functionality that is specific to your game.
open class OctopusGameCoordinator: GKStateMachine, OctopusScenePresenter, ObservableObject {
    
    /// Invoked by the `OctopusSpriteKitViewController` to start the game after the system/application presents the view.
    ///
    /// This should be set during `OctopusAppDelegate.applicationWillLaunchOctopusKit()` after the app launches.
    public let initialStateClass: OctopusGameState.Type
    
    public fileprivate(set) var didEnterInitialState: Bool = false

    public var currentGameState: OctopusGameState? {

        // NOTE: SWIFT LIMITATION: This property should be @Published but we cannot do that because
        // "Property wrapper cannot be applied to a computed property" and
        // "willSet cannot be provided together with a getter"
        // and we cannot provide a `willSet` for `GKStateMachine.currentState` because
        // "Cannot observe read-only property currentState; it can't change" :(
        // Okay so we'll just use objectWillChange.send() in the enter(_:) override below.
        // HOWEVER, even without objectWillChange.send() the derived properties in SwiftUI views depending on `currentGameState` seem to update just fine. Not sure about all this yet.

        get {
            if  let currentGameState = self.currentState as? OctopusGameState {
                return currentGameState
            } else {
                OctopusKit.logForWarnings.add("Cannot cast \(String(optional: currentState)) as OctopusGameState")
                return nil
            }
        }
        
    }
        
    public weak var viewController: OctopusViewController? {
        didSet {
            OctopusKit.logForFramework.add("\(String(optional: oldValue)) → \(String(optional: viewController))")
        }
    }
    
    public var spriteKitView: SKView? {
        viewController?.spriteKitView
    }

    @Published public var currentScene: OctopusScene? {
           didSet {
               OctopusKit.logForFramework.add("\(String(optional: oldValue)) → \(String(optional: currentScene))")
           }
       }
    
    /// A global entity for encapsulating components which manage data that must persist across scenes, such as the overall game world, active play session, or network connections etc.
    ///
    /// - Important: Must be manually added to scenes that require it.
    public let entity: OctopusEntity

    public private(set) var notifications: [AnyCancellable] = []
    
    // MARK: - Life Cycle
    
    public init(states: [OctopusGameState],
                initialStateClass: OctopusGameState.Type)
    {
        OctopusKit.logForFramework.add("states: \(states) — initial: \(initialStateClass)")
        
        self.initialStateClass = initialStateClass
        self.entity = OctopusEntity(name: OctopusKit.Constants.Strings.gameCoordinatorEntityName)
        super.init(states: states)
        registerForNotifications()
    }
    
    private override init(states: [GKState]) {
        // The default initializer is hidden so that only `OctopusGameState` is accepted.
        fatalError("OctopusGameCoordinator(states:) not implemented. Initialize with OctopusGameCoordinator(states:initialStateClass:)")
    }
    
    fileprivate func registerForNotifications() {
        self.notifications = [
            
            NotificationCenter.default.publisher(for: OSApplication.didFinishLaunchingNotification)
                .sink { _ in OctopusKit.logForDebug.add("Application.didFinishLaunchingNotification") },
            
            NotificationCenter.default.publisher(for: OSApplication.willEnterForegroundNotification)
                .sink { _ in
                    OctopusKit.logForDebug.add("Application.willEnterForegroundNotification")
                    self.currentScene?.applicationWillEnterForeground()
            },
            
            NotificationCenter.default.publisher(for: OSApplication.didBecomeActiveNotification)
                .sink { _ in
                    OctopusKit.logForDebug.add("Application.didBecomeActiveNotification")
                    
                    // NOTE: Call `scene.applicationDidBecomeActive()` before `enterInitialState()` so we don't issue a superfluous unpause event to the very first scene of the game.
                    
                    // CHECK: Compare launch performance between calling `OctopusSceneController.enterInitialState()` from `OctopusAppDelegate.applicationDidBecomeActive(_:)`! versus `OctopusSceneController.viewWillLayoutSubviews()`
                    
                    if  let scene = self.currentScene {
                        scene.applicationDidBecomeActive()
                    }
                    else if !self.didEnterInitialState {
                        self.enterInitialState()
                    }
            },
            
            NotificationCenter.default.publisher(for: OSApplication.willResignActiveNotification)
                .sink { _ in
                    OctopusKit.logForDebug.add("Application.willResignActiveNotification")
                    self.currentScene?.applicationWillResignActive()
            },
            
            NotificationCenter.default.publisher(for: OSApplication.didEnterBackgroundNotification)
                .sink { _ in
                    OctopusKit.logForDebug.add("Application.didEnterBackgroundNotification")
                    self.currentScene?.applicationDidEnterBackground()
            }
        ]
    }
    
    open override func enter(_ stateClass: AnyClass) -> Bool {
        
        // We override this method to send `ObservableObject` updates for SwiftUI support.
        // See comments for the `currentGameState` property for an explanation.
        
        if self.canEnterState(stateClass) {
            self.objectWillChange.send()
        }
        
        return super.enter(stateClass)
    }
    
    /// Attempts to enter the state specified by `initialStateClass`.
    @discardableResult internal func enterInitialState() -> Bool {
        OctopusKit.logForFramework.add()
        
        guard OctopusKit.initialized else {
            fatalError("OctopusKit not initialized")
        }
        
        // Even though GKStateMachine should handle the correct transitions between states, this coordinator should only initiate the initial state only once, just to be extra safe, and also as a flag for other classes to refer to if needed.
        
        guard !didEnterInitialState else {
            OctopusKit.logForFramework.add("didEnterInitialState already set. currentState: \(String(optional: currentState))")
            return false
        }
        
        if viewController == nil {
            OctopusKit.logForDebug.add("enterInitialState() called before viewController was set — May not be able to display the first scene. Ignore this warning if the OctopusGameCoordinator was initialized early in the application life cycle.")
        }
        
        self.didEnterInitialState = enter(initialStateClass)
        return didEnterInitialState
    }

    deinit {
        OctopusKit.logForDeinits.add("\(self)")
    }

}