-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity encode is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- stream of coefficients that should be encoded
    s_axis_tdata: in std_logic_vector(95 downto 0);
    -- determine mode of encoding
    -- 0000 - kyber t/s (12b per coeff)
    -- 0001 - kyber u (11b per coeff)
    -- 0010 - kyber u (10b per coeff)
    -- 0011 - kyber v (5b per coeff)
    -- 0100 - kyber v (4b per coeff)
    -- 0101 - kyber m (1b per coeff)
    -- 1000 - dilithium (20b per coeff)
    -- 1001 - dilithium (18b per coeff)
    -- 1010 - dilithium t0 (13b per coeff)
    -- 1011 - dilithium t1 (10b per coeff)
    -- 1100 - dilithium w1 (6b per coeff)
    -- 1101 - dilithium w1 (4b per coeff)
    -- 1110 - dilithium s1/s2 (4b per coeff)
    -- 1111 - dilithium s1/s2 (3b per coeff)
    s_axis_tuser: in std_logic_vector(3 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- stream of bytes representing encoded coefficients
    m_axis_tdata: out std_logic_vector(63 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of encode is
    signal reg_ready_m_axis_tdata: std_logic_vector(95 downto 0);
    signal reg_ready_m_axis_tuser: std_logic_vector(3 downto 0);
    signal reg_ready_m_axis_tvalid, reg_ready_m_axis_tready: std_logic;

    -- bytes parsed from coefficients
    signal bytes, bytes_reg: std_logic_vector(47 downto 0);
    -- 3 downto 0 determines how `rotated_bytes` will be created from `bytes`
    -- 5 indicates `fifo_next` should be set if bytes are read
    signal bytes_mux, bytes_mux_reg: std_logic_vector(4 downto 0);
    signal bytes_rotated_vld, bytes_rotated_next: std_logic;

    signal bytes_overflow: std_logic_vector(43 downto 0);
    signal bytes_overflow_valid: std_logic_vector(15 downto 0);

    -- coeffs signals
    signal coeffs_shifted: std_logic_vector(95 downto 0);

    -- out data signals
    signal out_data: std_logic_vector(63 downto 0);
    signal out_data_vld, out_data_next: std_logic;

    signal state, state_reg: std_logic_vector(6 downto 0);
begin
    m_axis_tdata <= out_data;
    m_axis_tvalid <= out_data_vld;

    reg_ready: entity work.reg_ready
    generic map (
        DATA_WIDTH => 96,
        USER_WIDTH => 4
    )
    port map (
        clk => clk,
        rst => rst,

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => s_axis_tuser,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => reg_ready_m_axis_tdata,
        m_axis_tuser => reg_ready_m_axis_tuser,
        m_axis_tvalid => reg_ready_m_axis_tvalid,
        m_axis_tready => reg_ready_m_axis_tready
    );

    with reg_ready_m_axis_tuser select reg_ready_m_axis_tready <=
        bytes_rotated_next when "0011" | "0100" | "0101" | "1011" | "1100" | "1101" | "1110" | "1111",
        bytes_mux(4) and bytes_rotated_next when others;

    out_data_next <= not out_data_vld or m_axis_tready;

    proc_out: process(clk) is
    begin
        if rising_edge(clk) then
            if (bytes_rotated_vld and out_data_next) = '1' then
                for i in 0 to 10 loop
                    if bytes_overflow_valid(i) = '1' then
                        out_data(3 + 4 * i downto 4 * i) <= bytes_overflow(3 + 4 * i downto 4 * i);
                    end if;
                end loop;

                case bytes_mux_reg(3 downto 2) is
                    when "00" =>
                        out_data(63 downto 48) <= bytes_reg(15 downto 0);
                    when "01" =>
                        out_data(63 downto 48) <= bytes_reg(31 downto 16);
                    when "10" =>
                        out_data(63 downto 32) <= bytes_reg(47 downto 16);
                    when others =>
                end case;

                case bytes_mux_reg(3 downto 0) is
                    when "0000" =>
                        out_data(47 downto 0) <= bytes_reg(47 downto 0);
                    when "0100" =>
                        out_data(63 downto 48) <= bytes_reg(15 downto 0);
                        bytes_overflow(31 downto 0) <= bytes_reg(47 downto 16);
                    when "1000" =>
                        out_data(63 downto 32) <= bytes_reg(31 downto 0);
                        bytes_overflow(15 downto 0) <= bytes_reg(47 downto 32);
                    when "1100" =>
                        out_data(63 downto 16) <= bytes_reg(47 downto 0);
                    when "0001" =>
                        out_data(47 downto 44) <= bytes_reg(47 downto 44);
                        bytes_overflow(31 downto 0) <= bytes_reg(47 downto 16);
                    when "0101" =>
                        out_data(31 downto 28) <= bytes_reg(47 downto 44);
                        out_data(47 downto 32) <= bytes_reg(15 downto 0);
                        bytes_overflow(15 downto 0) <= bytes_reg(47 downto 32);
                    when "1001" =>
                        out_data(15 downto 12) <= bytes_reg(47 downto 44);
                        out_data(31 downto 16) <= bytes_reg(15 downto 0);
                    when "1101" =>
                        out_data(63 downto 60) <= bytes_reg(47 downto 44);
                        bytes_overflow(43 downto 0) <= bytes_reg(43 downto 0);
                    when "0010" =>
                        out_data(47 downto 40) <= bytes_reg(47 downto 40);
                        bytes_overflow(31 downto 0) <= bytes_reg(47 downto 16);
                    when "0110" =>
                        out_data(31 downto 24) <= bytes_reg(47 downto 40);
                        out_data(47 downto 32) <= bytes_reg(15 downto 0);
                        bytes_overflow(15 downto 0) <= bytes_reg(47 downto 32);
                    when "1010" =>
                        out_data(15 downto 8) <= bytes_reg(47 downto 40);
                        out_data(31 downto 16) <= bytes_reg(15 downto 0);
                    when "1110" =>
                        out_data(63 downto 56) <= bytes_reg(47 downto 40);
                        bytes_overflow(39 downto 0) <= bytes_reg(39 downto 0);
                    when "0011" =>
                        out_data(47 downto 36) <= bytes_reg(47 downto 36);
                        bytes_overflow(31 downto 0) <= bytes_reg(47 downto 16);
                    when "0111" =>
                        out_data(31 downto 20) <= bytes_reg(47 downto 36);
                        out_data(47 downto 32) <= bytes_reg(15 downto 0);
                    when "1011" =>
                        out_data(15 downto 4) <= bytes_reg(47 downto 36);
                        out_data(31 downto 16) <= bytes_reg(15 downto 0);
                    when others =>
                        out_data(63 downto 52) <= bytes_reg(47 downto 36);
                        bytes_overflow(35 downto 0) <= bytes_reg(35 downto 0);
                end case;
            end if;

            if rst = '1' then
                out_data_vld <= '0';
            else
                if (bytes_rotated_vld and out_data_next) = '1' then
                    case state_reg is
                        -- 12b (kyber)
                        when "0000001" | "0000010" | "0000011" => out_data_vld <= '1';
                        -- 11b (kyber)
                        when "0000100" | "0000101" | "0000111" | "0001000" | "0001010" | "0001011" | "0001101" | "0001110" | "0010000" | "0010001" | "0010010" => out_data_vld <= '1';
                        -- 10b, 5b (kyber), 20b (dilithium), 10b (dilithium)
                        when "0010011" | "0010101" | "0010110" | "0011000" | "0011001" => out_data_vld <= '1';
                        -- 4b (kyber)
                        when "0011010" => out_data_vld <= '1';
                        -- 1b (kyber)
                        when "0100001" => out_data_vld <= '1';
                        -- 18b (dilithium)
                        when "0100010" | "0100100" | "0100110" | "0101000" | "0101001" | "0101011" | "0101101" | "0101111" | "0110000"  => out_data_vld <= '1';
                        -- 13b (dilithium)
                        when "0110010" | "0110100" | "0110111" | "0111001" | "0111100" | "0111110" | "1000001" | "1000011" | "1000110" | "1001000" | "1001011" | "1001101" | "1001111" => out_data_vld <= '1';
                        -- 6b (dilithium)
                        when "1010001" | "1010100" | "1010110" => out_data_vld <= '1';
                        -- 4b (dilithium)
                        when "1011001" => out_data_vld <= '1';
                        -- 3b (dilithium)
                        when "1011110" | "1100011" | "1101000" => out_data_vld <= '1';
                        when others => out_data_vld <= '0';
                    end case;
                elsif m_axis_tready = '1' then
                    out_data_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    proc_coeffs_shifted: process(all) is
    begin
        coeffs_shifted <= reg_ready_m_axis_tdata;

        -- 11b (kyber)
        if reg_ready_m_axis_tuser(0) = '1' then
            for i in 1 to 3 loop
                coeffs_shifted(10 + 11 * i downto 11 * i) <= reg_ready_m_axis_tdata(10 + 12 * i downto 12 * i);
                coeffs_shifted(58 + 11 * i downto 48 + 11 * i) <= reg_ready_m_axis_tdata(10 + 12 * (i + 4) downto 12 * (i + 4));
            end loop;
        end if;

        -- 10b (kyber)
        if reg_ready_m_axis_tuser(1) = '1' then
            for i in 1 to 3 loop
                coeffs_shifted(9 + 10 * i downto 10 * i) <= reg_ready_m_axis_tdata(9 + 12 * i downto 12 * i);
                coeffs_shifted(57 + 10 * i downto 48 + 10 * i) <= reg_ready_m_axis_tdata(9 + 12 * (i + 4) downto 12 * (i + 4));
            end loop;

            -- 5b (kyber)
            if reg_ready_m_axis_tuser(0) = '1' then
                for i in 1 to 7 loop
                    coeffs_shifted(4 + 5 * i downto 5 * i) <= reg_ready_m_axis_tdata(4 + 12 * i downto 12 * i);
                end loop;
            end if;
        end if;

        -- 4b (kyber)
        if reg_ready_m_axis_tuser(2) = '1' then
            for i in 1 to 7 loop
                coeffs_shifted(3 + 4 * i downto 4 * i) <= reg_ready_m_axis_tdata(3 + 12 * i downto 12 * i);
            end loop;

            -- 1b (kyber)
            if reg_ready_m_axis_tuser(0) = '1' then
                for i in 1 to 7 loop
                    coeffs_shifted(i) <= reg_ready_m_axis_tdata(12 * i);
                end loop;
            end if;
        end if;

        -- 20b (dilithium)
        if reg_ready_m_axis_tuser(3) = '1' then
            coeffs_shifted(19 downto 0) <= reg_ready_m_axis_tdata(19 downto 0);
            coeffs_shifted(39 downto 20) <= reg_ready_m_axis_tdata(43 downto 24);
            coeffs_shifted(87 downto 68) <= reg_ready_m_axis_tdata(91 downto 72);

            -- 18b (dilithium)
            if reg_ready_m_axis_tuser(0) = '1' then
                coeffs_shifted(35 downto 18) <= reg_ready_m_axis_tdata(41 downto 24);
                coeffs_shifted(65 downto 48) <= reg_ready_m_axis_tdata(65 downto 48);
                coeffs_shifted(83 downto 66) <= reg_ready_m_axis_tdata(89 downto 72);
            end if;

            -- 13b (dilithium)
            if reg_ready_m_axis_tuser(1) = '1' then
                coeffs_shifted(12 downto 0) <= reg_ready_m_axis_tdata(12 downto 0);
                coeffs_shifted(25 downto 13) <= reg_ready_m_axis_tdata(36 downto 24);
                coeffs_shifted(49 downto 37) <= reg_ready_m_axis_tdata(36 downto 24);
                coeffs_shifted(62 downto 50) <= reg_ready_m_axis_tdata(60 downto 48);
                coeffs_shifted(75 downto 63) <= reg_ready_m_axis_tdata(84 downto 72);

                -- 10b (dilithium)
                if reg_ready_m_axis_tuser(0) = '1' then
                    for i in 0 to 3 loop
                        coeffs_shifted(9 + 10 * i downto 10 * i) <= reg_ready_m_axis_tdata(9 + 24 * i downto 24 * i);
                    end loop;
                end if;
            end if;

            -- 6b (dilithium)
            if reg_ready_m_axis_tuser(2) = '1' then
                for i in 1 to 3 loop
                    coeffs_shifted(5 + 6 * i downto 6 * i) <= reg_ready_m_axis_tdata(5 + 24 * i downto 24 * i);
                end loop;

                -- 4b (dilithium)
                if (reg_ready_m_axis_tuser(0) or reg_ready_m_axis_tuser(1)) = '1' then
                    for i in 0 to 3 loop
                        coeffs_shifted(3 + 4 * i downto 4 * i) <= reg_ready_m_axis_tdata(3 + 24 * i downto 24 * i);
                    end loop;
                end if;

                -- 3b (dilithium)
                if (reg_ready_m_axis_tuser(0) and reg_ready_m_axis_tuser(1)) = '1' then
                    for i in 0 to 3 loop
                        coeffs_shifted(2 + 3 * i downto 3 * i) <= reg_ready_m_axis_tdata(2 + 24 * i downto 24 * i);
                    end loop;
                end if;
            end if;
        end if;
    end process;

    proc_bytes: process(all) is
    begin
        case reg_ready_m_axis_tuser is
            when "0011" | "0100" | "0101" | "1011" | "1100" | "1101" | "1110" | "1111" => bytes <= coeffs_shifted(47 downto 0);
            when others => bytes <= coeffs_shifted(95 downto 48) when bytes_mux(4) = '1' else coeffs_shifted(47 downto 0);
        end case;
    end process;

    bytes_rotated_next <= not bytes_rotated_vld or out_data_next;

    proc_bytes_rotated: process(clk) is
    begin
        if rising_edge(clk) then
            if (reg_ready_m_axis_tvalid and bytes_rotated_next) = '1' then
                state_reg <= state;
                bytes_mux_reg <= bytes_mux;

                case bytes_mux(1 downto 0) is
                    when "00" => bytes_reg <= bytes;
                    when "01" => bytes_reg(47 downto 0) <= bytes(3 downto 0) & bytes(47 downto 4);
                    when "10" => bytes_reg(47 downto 0) <= bytes(7 downto 0) & bytes(47 downto 8);
                    when others => bytes_reg(47 downto 0) <= bytes(11 downto 0) & bytes(47 downto 12);
                end case;
            end if;

            if rst = '1' then
                bytes_rotated_vld <= '0';

                state <= "0000000";
                bytes_mux <= "00000";
            else
                if reg_ready_m_axis_tvalid = '1' then
                    bytes_rotated_vld <= '1';
                elsif bytes_rotated_next = '1' then
                    bytes_rotated_vld <= '0';
                end if;

                if (reg_ready_m_axis_tvalid and bytes_rotated_next) = '1' then
                    bytes_overflow_valid <= (others => '0');

                    case state is
                        when "0000000" =>
                            bytes_overflow_valid <= x"ffff";

                            case reg_ready_m_axis_tuser is
                                when "0001" => bytes_mux <= "10001";
                                when "0010" => bytes_mux <= "10010";
                                when "0011" => bytes_mux <= "10010";
                                when "0100" => bytes_mux <= "11000";
                                when "0101" => bytes_mux <= "11010";
                                when "1000" => bytes_mux <= "10010";
                                when "1001" => bytes_mux <= "10011";
                                when "1010" => bytes_mux <= "10110";
                                when "1011" => bytes_mux <= "10010";
                                when "1100" => bytes_mux <= "10110";
                                when "1101" | "1110" => bytes_mux <= "11100";
                                when "1111" => bytes_mux <= "11001";
                                when others => bytes_mux <= "10100";
                            end case;
                        -- 12b (kyber)
                        when "0000001" => bytes_mux <= "01000"; bytes_overflow_valid <= x"f000";
                        when "0000010" => bytes_mux <= "11100"; bytes_overflow_valid <= x"ffff";
                        when "0000011" => bytes_mux <= "00000"; bytes_overflow_valid <= x"ffff";
                        -- 11b (kyber)
                        when "0000100" => bytes_mux <= "00110"; bytes_overflow_valid <= x"f800";
                        when "0000101" => bytes_mux <= "11011"; bytes_overflow_valid <= x"ffff";
                        when "0000110" => bytes_mux <= "00100"; bytes_overflow_valid <= x"ffff";
                        when "0000111" => bytes_mux <= "10101"; bytes_overflow_valid <= x"f000";
                        when "0001000" => bytes_mux <= "01010"; bytes_overflow_valid <= x"ffff";
                        when "0001001" => bytes_mux <= "11111"; bytes_overflow_valid <= x"ffff";
                        when "0001010" => bytes_mux <= "01000"; bytes_overflow_valid <= x"e000";
                        when "0001011" => bytes_mux <= "11001"; bytes_overflow_valid <= x"ffff";
                        when "0001100" => bytes_mux <= "01110"; bytes_overflow_valid <= x"ffff";
                        when "0001101" => bytes_mux <= "10011"; bytes_overflow_valid <= x"c000";
                        when "0001110" => bytes_mux <= "01100"; bytes_overflow_valid <= x"ffff";
                        when "0001111" => bytes_mux <= "11101"; bytes_overflow_valid <= x"ffff";
                        when "0010000" => bytes_mux <= "00010"; bytes_overflow_valid <= x"8000";
                        when "0010001" => bytes_mux <= "10111"; bytes_overflow_valid <= x"ffff";
                        when "0010010" => bytes_mux <= "00000"; bytes_overflow_valid <= x"ffff";
                        -- 10b, 5b (kyber), 20b, 10b (dilithium)
                        when "0010011" => bytes_mux <= "01100";
                        when "0010100" => bytes_mux <= "11110"; bytes_overflow_valid <= x"ffff";
                        when "0010101" => bytes_mux <= "01000";
                        when "0010110" => bytes_mux <= "11010"; bytes_overflow_valid <= x"ffff";
                        when "0010111" => bytes_mux <= "00100"; bytes_overflow_valid <= x"ffff";
                        when "0011000" => bytes_mux <= "10110";
                        when "0011001" => bytes_mux <= "00000"; bytes_overflow_valid <= x"ffff";
                        -- 4b (kyber)
                        when "0011010" => bytes_mux <= "00000";
                        -- 1b (kyber)
                        when "0011011" => bytes_mux <= "11100";
                        when "0011100" => bytes_mux <= "10110";
                        when "0011101" => bytes_mux <= "11000";
                        when "0011110" => bytes_mux <= "10010";
                        when "0011111" => bytes_mux <= "10100";
                        when "0100000" => bytes_mux <= "11110";
                        when "0100001" => bytes_mux <= "00000";
                        -- 18b (dilithium)
                        when "0100010" => bytes_mux <= "01010";
                        when "0100011" => bytes_mux <= "10001"; bytes_overflow_valid <= x"ffff";
                        when "0100100" => bytes_mux <= "01100";
                        when "0100101" => bytes_mux <= "11111"; bytes_overflow_valid <= x"ffff";
                        when "0100110" => bytes_mux <= "00110";
                        when "0100111" => bytes_mux <= "11101"; bytes_overflow_valid <= x"ffff";
                        when "0101000" => bytes_mux <= "01000";
                        when "0101001" => bytes_mux <= "11011"; bytes_overflow_valid <= x"ffff";
                        when "0101010" => bytes_mux <= "00010"; bytes_overflow_valid <= x"ffff";
                        when "0101011" => bytes_mux <= "11001";
                        when "0101100" => bytes_mux <= "00100"; bytes_overflow_valid <= x"ffff";
                        when "0101101" => bytes_mux <= "10111";
                        when "0101110" => bytes_mux <= "01110"; bytes_overflow_valid <= x"ffff";
                        when "0101111" => bytes_mux <= "10101";
                        when "0110000" => bytes_mux <= "00000"; bytes_overflow_valid <= x"ffff";
                        -- 13b (dilithium)
                        when "0110001" => bytes_mux <= "01111";
                        when "0110010" => bytes_mux <= "11001";
                        when "0110011" => bytes_mux <= "00010"; bytes_overflow_valid <= x"ffff";
                        when "0110100" => bytes_mux <= "10000";
                        when "0110101" => bytes_mux <= "00101";
                        when "0110110" => bytes_mux <= "11111";
                        when "0110111" => bytes_mux <= "01100";
                        when "0111000" => bytes_mux <= "10010"; bytes_overflow_valid <= x"ffff";
                        when "0111001" => bytes_mux <= "01011";
                        when "0111010" => bytes_mux <= "10101"; bytes_overflow_valid <= x"ffff";
                        when "0111011" => bytes_mux <= "01110";
                        when "0111100" => bytes_mux <= "11100";
                        when "0111101" => bytes_mux <= "00001"; bytes_overflow_valid <= x"ffff";
                        when "0111110" => bytes_mux <= "11011";
                        when "0111111" => bytes_mux <= "01000"; bytes_overflow_valid <= x"ffff";
                        when "1000000" => bytes_mux <= "11110";
                        when "1000001" => bytes_mux <= "00111";
                        when "1000010" => bytes_mux <= "10001"; bytes_overflow_valid <= x"ffff";
                        when "1000011" => bytes_mux <= "01010";
                        when "1000100" => bytes_mux <= "11000"; bytes_overflow_valid <= x"ffff";
                        when "1000101" => bytes_mux <= "01101";
                        when "1000110" => bytes_mux <= "10111";
                        when "1000111" => bytes_mux <= "00100"; bytes_overflow_valid <= x"ffff";
                        when "1001000" => bytes_mux <= "11010";
                        when "1001001" => bytes_mux <= "00011"; bytes_overflow_valid <= x"ffff";
                        when "1001010" => bytes_mux <= "11101";
                        when "1001011" => bytes_mux <= "00110";
                        when "1001100" => bytes_mux <= "10100"; bytes_overflow_valid <= x"ffff";
                        when "1001101" => bytes_mux <= "01001";
                        when "1001110" => bytes_mux <= "10011"; bytes_overflow_valid <= x"ffff";
                        when "1001111" => bytes_mux <= "00000";
                        -- 6b (dilithium)
                        when "1010000" => bytes_mux <= "10100";
                        when "1010001" => bytes_mux <= "11010";
                        when "1010010" => bytes_mux <= "11000"; bytes_overflow_valid <= x"ffff";
                        when "1010011" => bytes_mux <= "11110";
                        when "1010100" => bytes_mux <= "11100";
                        when "1010101" => bytes_mux <= "10010"; bytes_overflow_valid <= x"ffff";
                        when "1010110" => bytes_mux <= "00000";
                        -- 4b (dilithium)
                        when "1010111" => bytes_mux <= "11000";
                        when "1011000" => bytes_mux <= "10100";
                        when "1011001" => bytes_mux <= "00000";
                        -- 3b (dilithium)
                        when "1011010" => bytes_mux <= "10110";
                        when "1011011" => bytes_mux <= "10011";
                        when "1011100" => bytes_mux <= "10100";
                        when "1011101" => bytes_mux <= "11101";
                        when "1011110" => bytes_mux <= "11010";
                        when "1011111" => bytes_mux <= "10111"; bytes_overflow_valid <= x"ffff";
                        when "1100000" => bytes_mux <= "11000";
                        when "1100001" => bytes_mux <= "10001";
                        when "1100010" => bytes_mux <= "11110";
                        when "1100011" => bytes_mux <= "11011";
                        when "1100100" => bytes_mux <= "11100"; bytes_overflow_valid <= x"ffff";
                        when "1100101" => bytes_mux <= "10101";
                        when "1100110" => bytes_mux <= "10010";
                        when "1100111" => bytes_mux <= "11111";
                        when "1101000" => bytes_mux <= "00000";
                        when others =>
                    end case;

                    case state is
                        when "0000000" =>
                            case reg_ready_m_axis_tuser is
                                when "0001" => state <= "0000100";
                                when "0010" => state <= "0010011";
                                when "0011" => state <= "0010011";
                                when "0100" => state <= "0011010";
                                when "0101" => state <= "0011011";
                                when "1000" => state <= "0010011";
                                when "1001" => state <= "0100010";
                                when "1010" => state <= "0110001";
                                when "1011" => state <= "0010011";
                                when "1100" => state <= "1010000";
                                when "1101" | "1110" => state <= "1010111";
                                when "1111" => state <= "1011010";
                                when others => state <= "0000001";
                            end case;
                        when "0000011" | "0010010" | "0011001" | "0011010" | "0100001" | "0110000" | "1001111" | "1010110" | "1011001" | "1101000" =>
                            state <= "0000000";
                        when others =>
                            state <= std_logic_vector(unsigned(state) + 1);
                    end case;
                end if;
            end if;
        end if;
    end process;
end;
