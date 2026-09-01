---------------------------------------------------------------------------------
-- file name: xorshift32.vhd
-- DESCRIPTION:
--		32-bit PRNG (George Marsaglia, 2003)
--		x ^= x << 13;
--		x ^= x >> 17;
--		x ^= x << 5;
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


entity xorshift32 is
	port (
		clk			: in  std_logic;
		rst_n		: in  std_logic;
		enable		: in std_logic;
		load_seed	: in  std_logic;
		seed_in		: in  std_logic_vector(31 downto 0);

		rand_out  : out std_logic_vector(31 downto 0)
	);
end entity;

architecture rtl of xorshift32 is
	signal reg : std_logic_vector(31 downto 0);

begin

	rand_out <= reg;

	process(clk, rst_n)

	variable temp : std_logic_vector(31 downto 0);
	begin
		if rst_n = '0' then
			reg <= x"00000001";
		elsif rising_edge(clk) then

			if load_seed = '1' then
				reg <= seed_in;
			elsif enable = '1' then
				temp := reg;
				temp := temp xor ( temp(18 downto 0) & "0000000000000" );-- x ^= x << 13
				temp := temp xor ( "00000000000000000" & temp(31 downto 17) );--x ^= x >> 17
				temp := temp xor ( temp(26 downto 0) & "00000" );--x ^= x << 5

				reg <= temp;
			end if;

		end if;
	end process;

end rtl;
