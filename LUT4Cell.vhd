library ieee;
use ieee.std_logic_1164.all;
use IEEE.NUMERIC_STD.ALL;


entity Lut4Cell is 
	port(
		F 				: in std_logic_vector(15 downto 0); 
		Address 		: in std_logic_vector(3 downto 0);
		Out_signal 	: out std_logic
	);
end Lut4Cell;


architecture Behavioral of Lut4Cell is
begin
		out_signal <= F(to_integer(unsigned(address)));
end Behavioral;
