#include "xparameters.h"

#include "ov5640/OV5640.h"
#include "ov5640/ScuGicInterruptController.h"
#include "ov5640/PS_GPIO.h"
#include "ov5640/AXI_VDMA.h"
#include "ov5640/PS_IIC.h"

#include "MIPI_D_PHY_RX.h"
#include "MIPI_CSI_2_RX.h"

#include "xgpio.h"
#include "xuartps.h"

#define IRPT_CTL_DEVID      XPAR_PS7_SCUGIC_0_DEVICE_ID
#define GPIO_DEVID          XPAR_PS7_GPIO_0_DEVICE_ID
#define GPIO_IRPT_ID        XPAR_PS7_GPIO_0_INTR
#define CAM_I2C_DEVID       XPAR_PS7_I2C_0_DEVICE_ID
#define CAM_I2C_IRPT_ID     XPAR_PS7_I2C_0_INTR
#define VDMA_DEVID          XPAR_AXIVDMA_0_DEVICE_ID
#define VDMA_MM2S_IRPT_ID   XPAR_FABRIC_AXI_VDMA_0_MM2S_INTROUT_INTR
#define VDMA_S2MM_IRPT_ID   XPAR_FABRIC_AXI_VDMA_0_S2MM_INTROUT_INTR

#define DDR_BASE_ADDR       XPAR_DDR_MEM_BASEADDR
#define MEM_BASE_ADDR       (DDR_BASE_ADDR + 0x0A000000)
#define GAMMA_BASE_ADDR     XPAR_AXI_GAMMACORRECTION_0_BASEADDR

#define SW_BTN_GPIO_DEVID   XPAR_AXI_GPIO_0_DEVICE_ID
#define SW_CHANNEL          1
#define BTN_CHANNEL         2

#define UART_DEVID          XPAR_PS7_UART_1_DEVICE_ID

using namespace digilent;

static XGpio   sw_btn_gpio;
static XUartPs uart_inst;

static u8 prev_sw   = 0xFF;
static u8 prev_sw2  = 0xFF;
static u8 prev_btn  = 0xFF;

int read_key(void)
{
    if (!XUartPs_IsReceiveData(uart_inst.Config.BaseAddress))
        return -1;

    return (int)XUartPs_RecvByte(uart_inst.Config.BaseAddress);
}

void print_sw_mode(u8 sw)
{
    switch (sw & 0x3) {
        case 0x0: xil_printf("[MODE] sw[1:0]=00 -> BYPASS (passthrough)\r\n"); break;
        case 0x1: xil_printf("[MODE] sw[1:0]=01 -> SINGLE-PIXEL filter mode\r\n"); break;
        case 0x2: xil_printf("[MODE] sw[1:0]=10 -> MULTI-PIXEL filter mode (3x3)\r\n"); break;
        case 0x3: xil_printf("[MODE] sw[1:0]=11 -> EXTRA FEATURES mode\r\n"); break;
    }
}

void print_btn_mode(u8 sw, u8 sw2, u8 btn)
{
    btn &= 0xF;
    sw  &= 0x3;
    sw2 &= 0x1;

    if (sw2) {
        if      (btn & 0x1) xil_printf("[TINT] BLUE tint selected\r\n");
        else if (btn & 0x2) xil_printf("[TINT] GREEN tint selected\r\n");
        else if (btn & 0x4) xil_printf("[TINT] RED tint selected\r\n");
        else                xil_printf("[TINT] Tint enabled, no colour button pressed\r\n");
        return;
    }

    if (sw == 0x0) return;

    if (sw == 0x1) {
        if      (btn & 0x1) xil_printf("[FILTER] Single: GRAYSCALE\r\n");
        else if (btn & 0x2) xil_printf("[FILTER] Single: INVERT\r\n");
        else if (btn & 0x4) xil_printf("[FILTER] Single: BRIGHTNESS\r\n");
        else if (btn & 0x8) xil_printf("[FILTER] Single: THRESHOLD\r\n");
        else                xil_printf("[FILTER] Single: passthrough (no button)\r\n");
    }
    else if (sw == 0x2) {
        if      (btn & 0x1) xil_printf("[FILTER] Multi: BLUR\r\n");
        else if (btn & 0x2) xil_printf("[FILTER] Multi: SOBEL EDGE\r\n");
        else if (btn & 0x4) xil_printf("[FILTER] Multi: SHARPEN\r\n");
        else if (btn & 0x8) xil_printf("[FILTER] Multi: GRAYSCALE\r\n");
        else                xil_printf("[FILTER] Multi: passthrough (no button)\r\n");
    }
    else if (sw == 0x3) {
        if      (btn & 0x1) xil_printf("[FILTER] Extra: PLASMA WAVE\r\n");
        else if (btn & 0x2) xil_printf("[FILTER] Extra: SOUND-REACTIVE\r\n");
        else if (btn & 0x4) xil_printf("[FILTER] Extra: ES3F1 SPRITE\r\n");
        else                xil_printf("[FILTER] Extra: passthrough (no button)\r\n");
    }
}

void check_and_print_mode_changes(void)
{
    u8 sw_all = (u8)(XGpio_DiscreteRead(&sw_btn_gpio, SW_CHANNEL) & 0xF);
    u8 sw     = sw_all & 0x3;
    u8 sw2    = (sw_all >> 2) & 0x1;
    u8 btn    = (u8)(XGpio_DiscreteRead(&sw_btn_gpio, BTN_CHANNEL) & 0xF);

    if (sw != prev_sw || sw2 != prev_sw2 || btn != prev_btn) {
        xil_printf("\r\n========================================\r\n");

        if (sw != prev_sw)
            print_sw_mode(sw);

        if (sw2 != prev_sw2) {
            if (sw2)
                xil_printf("[TINT] sw[2]=ON  -> btn0=BLUE btn1=GREEN btn2=RED\r\n");
            else
                xil_printf("[TINT] sw[2]=OFF -> tint disabled\r\n");
        }

        print_btn_mode(sw, sw2, btn);

        xil_printf("========================================\r\n");

        prev_sw  = sw;
        prev_sw2 = sw2;
        prev_btn = btn;
    }
}

void pipeline_mode_change(
    AXI_VDMA<ScuGicInterruptController>& vdma_driver,
    OV5640& cam,
    VideoOutput& vid,
    Resolution res,
    OV5640_cfg::mode_t mode)
{
    vdma_driver.resetWrite();

    MIPI_CSI_2_RX_mWriteReg(
        XPAR_MIPI_CSI_2_RX_0_S_AXI_LITE_BASEADDR,
        CR_OFFSET,
        (CR_RESET_MASK & ~CR_ENABLE_MASK)
    );

    MIPI_D_PHY_RX_mWriteReg(
        XPAR_MIPI_D_PHY_RX_0_S_AXI_LITE_BASEADDR,
        CR_OFFSET,
        (CR_RESET_MASK & ~CR_ENABLE_MASK)
    );

    cam.reset();

    vdma_driver.configureWrite(
        timing[static_cast<int>(res)].h_active,
        timing[static_cast<int>(res)].v_active
    );

    Xil_Out32(GAMMA_BASE_ADDR, 3);
    cam.init();

    vdma_driver.enableWrite();

    MIPI_CSI_2_RX_mWriteReg(
        XPAR_MIPI_CSI_2_RX_0_S_AXI_LITE_BASEADDR,
        CR_OFFSET,
        CR_ENABLE_MASK
    );

    MIPI_D_PHY_RX_mWriteReg(
        XPAR_MIPI_D_PHY_RX_0_S_AXI_LITE_BASEADDR,
        CR_OFFSET,
        CR_ENABLE_MASK
    );

    cam.set_mode(mode);
    cam.set_awb(OV5640_cfg::awb_t::AWB_ADVANCED);

    vid.reset();
    vdma_driver.resetRead();

    vid.configure(res);

    vdma_driver.configureRead(
        timing[static_cast<int>(res)].h_active,
        timing[static_cast<int>(res)].v_active
    );

    vid.enable();
    vdma_driver.enableRead();
}

int main()
{
    ScuGicInterruptController irpt_ctl(IRPT_CTL_DEVID);
    PS_GPIO<ScuGicInterruptController> gpio_driver(GPIO_DEVID, irpt_ctl, GPIO_IRPT_ID);
    PS_IIC<ScuGicInterruptController>  iic_driver(CAM_I2C_DEVID, irpt_ctl, CAM_I2C_IRPT_ID, 100000);

    OV5640 cam(iic_driver, gpio_driver);

    AXI_VDMA<ScuGicInterruptController> vdma_driver(
        VDMA_DEVID,
        MEM_BASE_ADDR,
        irpt_ctl,
        VDMA_MM2S_IRPT_ID,
        VDMA_S2MM_IRPT_ID
    );

    VideoOutput vid(XPAR_VTC_0_DEVICE_ID, XPAR_VIDEO_DYNCLK_DEVICE_ID);

    pipeline_mode_change(
        vdma_driver,
        cam,
        vid,
        Resolution::R1920_1080_60_PP,
        OV5640_cfg::mode_t::MODE_1080P_1920_1080_30fps
    );

    xil_printf("Video init done.\r\n");

    {
        int status = XGpio_Initialize(&sw_btn_gpio, SW_BTN_GPIO_DEVID);
        if (status != XST_SUCCESS)
            xil_printf("ERROR: sw/btn GPIO init failed!\r\n");

        XGpio_SetDataDirection(&sw_btn_gpio, SW_CHANNEL,  0xFF);
        XGpio_SetDataDirection(&sw_btn_gpio, BTN_CHANNEL, 0xFF);

        xil_printf("sw/btn GPIO initialised.\r\n");
    }

    {
        XUartPs_Config *uart_cfg = XUartPs_LookupConfig(UART_DEVID);
        int status = XUartPs_CfgInitialize(&uart_inst, uart_cfg, uart_cfg->BaseAddress);

        if (status != XST_SUCCESS)
            xil_printf("ERROR: UART init failed!\r\n");

        XUartPs_SetBaudRate(&uart_inst, 115200);
        xil_printf("Non-blocking UART initialised.\r\n");
    }

    uint8_t read_char0 = 0;
    uint8_t read_char1 = 0;
    bool menu_printed = false;

    while (1) {
        check_and_print_mode_changes();

        if (!menu_printed) {
            xil_printf("\r\n\r\n\r\nPcam 5C MAIN OPTIONS\r\n");
            xil_printf("\r\nPlease press the key corresponding to the desired option:");
            xil_printf("\r\n  a. Change Resolution");
            xil_printf("\r\n  d. Change Image Format (Raw or RGB)");
            xil_printf("\r\n  g. Change Gamma Correction Factor Value");
            xil_printf("\r\n  h. Change AWB Settings\r\n\r\n");
            menu_printed = true;
        }

        int ch = read_key();
        if (ch == -1) continue;
        if (ch == '\r' || ch == '\n') continue;

        read_char0 = (uint8_t)ch;
        xil_printf("Read: %d\r\n", read_char0);
        menu_printed = false;

        switch (read_char0) {
            case 'a':
                xil_printf("\r\n  Please press the key corresponding to the desired resolution:");
                xil_printf("\r\n    1. 1280 x 720, 60fps");
                xil_printf("\r\n    2. 1920 x 1080, 15fps");
                xil_printf("\r\n    3. 1920 x 1080, 30fps\r\n");

                {
                    int sub = -1;
                    while (sub == -1 || sub == '\r' || sub == '\n') {
                        check_and_print_mode_changes();
                        sub = read_key();
                    }
                    read_char1 = (uint8_t)sub;
                }

                switch (read_char1) {
                    case '1':
                        pipeline_mode_change(vdma_driver, cam, vid,
                            Resolution::R1280_720_60_PP,
                            OV5640_cfg::mode_t::MODE_720P_1280_720_60fps);
                        xil_printf("Resolution change done.\r\n");
                        break;

                    case '2':
                        pipeline_mode_change(vdma_driver, cam, vid,
                            Resolution::R1920_1080_60_PP,
                            OV5640_cfg::mode_t::MODE_1080P_1920_1080_15fps);
                        xil_printf("Resolution change done.\r\n");
                        break;

                    case '3':
                        pipeline_mode_change(vdma_driver, cam, vid,
                            Resolution::R1920_1080_60_PP,
                            OV5640_cfg::mode_t::MODE_1080P_1920_1080_30fps);
                        xil_printf("Resolution change done.\r\n");
                        break;

                    default:
                        xil_printf("Selection outside available options.\r\n");
                        break;
                }
                break;

            case 'd':
                xil_printf("\r\n  1. RGB format   2. RAW format\r\n");

                {
                    int sub = -1;
                    while (sub == -1 || sub == '\r' || sub == '\n') {
                        check_and_print_mode_changes();
                        sub = read_key();
                    }
                    read_char1 = (uint8_t)sub;
                }

                switch (read_char1) {
                    case '1':
                        cam.set_isp_format(OV5640_cfg::isp_format_t::ISP_RGB);
                        xil_printf("Settings change done.\r\n");
                        break;

                    case '2':
                        cam.set_isp_format(OV5640_cfg::isp_format_t::ISP_RAW);
                        xil_printf("Settings change done.\r\n");
                        break;

                    default:
                        xil_printf("Selection outside available options.\r\n");
                        break;
                }
                break;

            case 'g':
                xil_printf("  1=1  2=1/1.2  3=1/1.5  4=1/1.8  5=1/2.2\r\n");

                {
                    int sub = -1;
                    while (sub == -1 || sub == '\r' || sub == '\n') {
                        check_and_print_mode_changes();
                        sub = read_key();
                    }
                    read_char1 = (uint8_t)sub;
                }

                read_char1 = read_char1 - 48;

                if ((read_char1 > 0) && (read_char1 < 6)) {
                    Xil_Out32(GAMMA_BASE_ADDR, read_char1 - 1);
                    xil_printf("Gamma changed.\r\n");
                } else {
                    xil_printf("Selection outside available options.\r\n");
                }
                break;

            case 'h':
                xil_printf("  1. Advanced AWB   2. Simple AWB   3. Disable AWB\r\n");

                {
                    int sub = -1;
                    while (sub == -1 || sub == '\r' || sub == '\n') {
                        check_and_print_mode_changes();
                        sub = read_key();
                    }
                    read_char1 = (uint8_t)sub;
                }

                switch (read_char1) {
                    case '1':
                        cam.set_awb(OV5640_cfg::awb_t::AWB_ADVANCED);
                        xil_printf("Enabled Advanced AWB\r\n");
                        break;

                    case '2':
                        cam.set_awb(OV5640_cfg::awb_t::AWB_SIMPLE);
                        xil_printf("Enabled Simple AWB\r\n");
                        break;

                    case '3':
                        cam.set_awb(OV5640_cfg::awb_t::AWB_DISABLED);
                        xil_printf("Disabled AWB\r\n");
                        break;

                    default:
                        xil_printf("Selection outside available options.\r\n");
                        break;
                }
                break;

            default:
                xil_printf("Selection outside available options.\r\n");
                break;
        }

        read_char1 = 0;
    }

    return 0;
}
