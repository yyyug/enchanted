//
import SwiftUI

struct SideBarStack<SidebarContent: View, Content: View>: View {
    let sidebarContent: SidebarContent
    let mainContent: Content
    let sidebarWidth: CGFloat
    @State var offset: CGFloat = 0
    @Binding var showSidebar: Bool
    
    init(sidebarWidth: CGFloat, showSidebar: Binding<Bool>, @ViewBuilder sidebar: ()->SidebarContent, @ViewBuilder content: ()->Content) {
        self.mainContent = content()
        self.sidebarContent = sidebar()
        self.sidebarWidth = sidebarWidth
        self._showSidebar = showSidebar
    }
    
    var body: some View {
        ZStack(alignment: .leading) {
            // Sidebar with proper background
            sidebarContent
                .frame(width: sidebarWidth, alignment: .center)
                .background(Color(.systemBackground))
                .offset(x: showSidebar ? offset - sidebarWidth : -sidebarWidth, y: 0)
                .gesture(DragGesture().onChanged({ gesture in
                    let t = gesture.translation.width
                    if t > 0 {
                        return
                    }
                    
                    withAnimation(.spring) {
                        offset = sidebarWidth + t
                    }
                }).onEnded({ gesture in
                    withAnimation(.spring) {
                        if -offset < 100 {
                            offset = 0
                        } else {
                            offset = sidebarWidth
                        }
                        showSidebar = false
                    }
                    
                }))
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(showSidebar ? .isModal : [])
                .accessibilityHidden(!showSidebar)
            
            mainContent
                .accessibilityHidden(showSidebar)
                .overlay(
                    Group {
                        if showSidebar {
                            Color.black
                                .ignoresSafeArea()
                                .opacity(0.3)
                                .onTapGesture {
                                    withAnimation(.spring) {
                                        offset = 0
                                        showSidebar = false
                                    }
                                }
                                .accessibilityHidden(true)
                        }
                    }
                )
                .offset(x: showSidebar ? offset : 0, y: 0)
            
        }
        .onChange(of: showSidebar) { oldValue, newValue in
            withAnimation(.spring) {
                offset = newValue ? sidebarWidth : 0
            }
        }
    }
}