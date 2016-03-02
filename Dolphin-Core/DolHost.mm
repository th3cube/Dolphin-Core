/*
Copyright (c) 2016, OpenEmu Team

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
* Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
* Neither the name of the OpenEmu Team nor the
names of its contributors may be used to endorse or promote products
derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#include "DolHost.h"
#include "OE_OSXJoystick.h"
#include <OpenGL/gl3.h>
#include <OpenGL/gl3ext.h>
#import  <Cocoa/Cocoa.h>

#include "Core/BootManager.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/Host.h"
#include "Core/State.h"
#include "Core/HW/GCPadEmu.h"
#include "Core/HW/Wiimote.h"
#include "Core/IPC_HLE/WII_IPC_HLE_Device_usb.h"
#include "Core/IPC_HLE/WII_IPC_HLE_WiiMote.h"
#include "Core/PowerPC/PowerPC.h"
#include "Common/Common.h"
#include "Common/CommonTypes.h"
#include "Common/Event.h"
#include "Common/MsgHandler.h"
#include "Common/Logging/LogManager.h"
#include "Common/GL/GLInterfaceBase.h"
#include "UICommon/UICommon.h"
#include "VideoCommon/VideoBackendBase.h"
#include "VideoCommon/VideoConfig.h"
#include "Videobackends/OGL/FramebufferManager.h"
#include "InputCommon/ControllerInterface/Device.h"
#include "InputCommon/ControllerInterface/ControllerInterface.h"
#include "InputCommon/ControllerInterface/ExpressionParser.h"
#include "AudioCommon/AudioCommon.h"

DolHost* DolHost::m_instance = nullptr;
static Common::Event updateMainFrameEvent;

DolHost* DolHost::GetInstance()
{
    if (DolHost::m_instance == nullptr)
        DolHost::m_instance = new DolHost();
    return DolHost::m_instance;
}

DolHost::DolHost()
{
}

void DolHost::Init(std::string supportDirectoryPath)
{
    UICommon::SetUserDirectory(supportDirectoryPath);
    UICommon::CreateDirectories();
    UICommon::Init();

    SConfig::GetInstance().bDSPHLE = true;
    SConfig::GetInstance().m_Volume = 50;
    SConfig::GetInstance().bOnScreenDisplayMessages = false;
}

# pragma mark - Execution
bool DolHost::LoadFileAtPath(const std::string& cpath)
{
    if(!BootManager::BootCore(cpath))
        return false;
    
    while (!Core::IsRunning())
        updateMainFrameEvent.Wait();

    SetUpPlayerInputs();
    
    return true;
}

void DolHost::Pause(bool flag)
{
    Core::EState state = flag ? Core::CORE_PAUSE : Core::CORE_RUN;
    Core::SetState(state);
}

void DolHost::RequestStop()
{
    Core::Stop();
    while (PowerPC::GetState() != PowerPC::CPU_POWERDOWN)
        usleep(1000);

}

void DolHost::UpdateFrame()
{
    while(Core::GetState() != Core::CORE_RUN)
    {
        Core::SetState(Core::CORE_RUN);
        updateMainFrameEvent.Set();
    }
}

# pragma mark - Core Thread
void DolHost::RunCore()
{
    Core::EmuThread();

    //Clean up after the EmuThread has ended
    VideoBackendBase::ClearList();
    SConfig::Shutdown();
    LogManager::Shutdown();
}

void DolHost::SetPresentationFBO(int RenderFBO)
{
    g_Config.iRenderFBO = RenderFBO;
}

# pragma mark - Save states
bool DolHost::SaveState(std::string saveStateFile)
{
    State::SaveAs(saveStateFile);
    return true;
}

bool DolHost::LoadState(std::string saveStateFile)
{
    State::LoadAs(saveStateFile);
    return true;
}

# pragma mark - Controls
void DolHost::SetUpPlayerInputs()
{
    struct {
        OEGCButton button;
        std::string identifier;
    } buttonToIdentifier[OEGCButtonCount] = {
        { OEGCButtonUp, "OEGCButtonUp" },
        { OEGCButtonDown, "OEGCButtonDown" },
        { OEGCButtonLeft, "OEGCButtonLeft" },
        { OEGCButtonRight, "OEGCButtonRight" },
        { OEGCButtonA, "OEGCButtonA" },
        { OEGCButtonB, "OEGCButtonB" },
        { OEGCButtonX, "OEGCButtonX" },
        { OEGCButtonY, "OEGCButtonY" },
        { OEGCButtonL, "OEGCButtonL" },
        { OEGCButtonR, "OEGCButtonR" },
        { OEGCButtonZ, "OEGCButtonZ" },
        { OEGCButtonStart, "OEGCButtonStart" },
        { OEGCAnalogUp, "OEGCAnalogUp" },
        { OEGCAnalogDown, "OEGCAnalogDown" },
        { OEGCAnalogLeft, "OEGCAnalogLeft" },
        { OEGCAnalogRight, "OEGCAnalogRight" },
        { OEGCAnalogCUp, "OEGCAnalogCUp" },
        { OEGCAnalogCDown, "OEGCAnalogCDown" },
        { OEGCAnalogCLeft, "OEGCAnalogCLeft" },
        { OEGCAnalogCRight, "OEGCAnalogCRight" },
    };

    std::vector<ciface::Core::Device*> devices = g_controller_interface.ControllerInterface::Devices();
    for (int player = 0; player < 4; ++player) {
        std::string qualifier = "OE_GameDev" + std::to_string(player);
        ciface::Core::Device* device = nullptr;
               for (auto& d : devices) {
                        if (d->GetName() == qualifier) {

                            device = d;
                            break;
                        }
               }
        if (device == nullptr)
                    continue;

        for (int inputIndex = 0; inputIndex < OEGCButtonCount; ++inputIndex) {
                        std::string identifier = buttonToIdentifier[inputIndex].identifier;
                        ciface::Core::Device::Input* input = g_controller_interface.ControllerInterface::FindInput(identifier, device);

                        m_playerInputs[player][buttonToIdentifier[inputIndex].button] = input;
        }
    }
}

void DolHost::SetButtonState(int button, int state, int player)
{
    ciface::Core::Device::Input* input = m_playerInputs[player - 1][button];
    input->SetState(state);
}

void DolHost::SetAxis(int button, float value, int player)
{
    ciface::Core::Device::Input* input = m_playerInputs[player - 1][button];
    input->SetState(value);
}

# pragma mark - Dolphin Host callbacks
void* Host_GetRenderHandle(){ return nullptr; }
bool Host_RendererHasFocus(){ return true; }
bool Host_RendererIsFullscreen(){ return false; }
void Host_SetWiiMoteConnectionState(int state) {}
void Host_GetRenderWindowSize(int& x, int& y, int& width, int& height)
{
    x = 0;
    y = 0;
    width = 640;
    height = 480;
}

void Host_SetStartupDebuggingParameters()
{
    NSLog(@"DolphinCore: Set Startup Debugging Parameters");
    SConfig& StartUp = SConfig::GetInstance();
    StartUp.bEnableDebugging = false;
    StartUp.bBootToPause = false;
    StartUp.bWii = false;
}

void Host_NotifyMapLoaded() {}
void Host_RefreshDSPDebuggerWindow() {}
void Host_Message(int Id) {}
void Host_UpdateTitle(const std::string&) {}
void Host_UpdateDisasmDialog() {}
void Host_UpdateMainFrame()
{
    updateMainFrameEvent.Set();
}

void Host_RequestRenderWindowSize(int, int) {}
void Host_RequestFullscreen(bool) {}
bool Host_UIHasFocus() { return false; }
void Host_ConnectWiimote(int wm_idx, bool connect)
{
    if (Core::IsRunning() && SConfig::GetInstance().bWii)
    {
        bool was_unpaused = Core::PauseAndLock(true);
        GetUsbPointer()->AccessWiiMote(wm_idx | 0x100)->Activate(connect);
        Host_UpdateMainFrame();
        Core::PauseAndLock(false, was_unpaused);
    }
}

void Host_ShowVideoConfig(void*, const std::string&, const std::string&) {}

