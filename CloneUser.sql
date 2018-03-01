DECLARE
		v_Model_UserName VARCHAR2(30) := UPPER('&Model_UserName');
	v_Cloned_UserName VARCHAR2(30) := UPPER('&Cloned_UserName');
	v_Skip_If_Model_User_Missing VARCHAR2(1) := '&Skip_If_Model_User_Missing';
	v_Remove_Cloned_User_If_Exists VARCHAR2(1) := '&Remove_Cloned_User_If_Exists';
	v_Retain_Same_Password VARCHAR2(1) := '&Retain_Same_Password';
	
	v_SQL               VARCHAR2(32000);
	v_Count             NUMBER;

	--Error Handling
	v_err_cd                NUMBER;                 --Error code SQLCODE
	v_sqlerrm               VARCHAR2(1024);         --Error message SQLERRM
	v_errm_generic          VARCHAR2(1024);         --Generic error message for this function with param values..
	v_msg_cur_operation     VARCHAR2(1024);         --Holds the message that identifies the specific operation in progress
 
	
	TYPE varchar2_TABLE IS TABLE OF VARCHAR2(32000);    
		
	FUNCTION Tokenize (str   VARCHAR2, 
					   delim CHAR) 
	RETURN VARCHAR2_TABLE 
	IS 
	  target     INT; 
	  i          INT; 
	  this_delim INT; 
	  last_delim INT; 
	  ret        VARCHAR2_TABLE := Varchar2_table(); 
	BEGIN 
	  i := 1; 
	  last_delim := 0; 
	  target := Length(Replace(str, delim, delim 
										   || ' ')) - Length(str); 

	  WHILE i <= target LOOP 
		  this_delim := Instr(str, delim, 1, i); 
		  ret.Extend(1); 
		  Ret(ret.last) := Substr(str, last_delim + 1, this_delim - last_delim - 1); 
		  i := i + 1; 
		  last_delim := this_delim; 
	  END LOOP; 

	  IF Substr(str, last_delim + 1) IS NOT NULL THEN 
		ret.Extend(1); 
		Ret(ret.last) := Substr(str, last_delim + 1); 
	  END IF; 

	  RETURN ret; 
	END;        
	
	PROCEDURE Execute_immediate(v_sql IN VARCHAR2) 
	IS 
	  ret_table VARCHAR2_TABLE := Varchar2_table(); 
	BEGIN 
	  IF v_sql IS NOT NULL THEN 
		ret_table := Tokenize(v_sql, ';'); 

		FOR i IN 1..ret_table.COUNT LOOP 
			IF Trim(Translate(Ret_table(i), Chr(13) 
											||Chr(10) 
											||Chr(9), ' ')) IS NOT NULL THEN 
			  --dbms_output.put_line('RET_TABLE(' || TO_CHAR(I) || ') - ' || ret_table(i)); 
			  EXECUTE IMMEDIATE Ret_table(i); 
			END IF; 
		END LOOP; 
	  END IF; 
	END;  

BEGIN
	v_msg_cur_operation := 'Check if user exists!';
	-------------------------------------------
	SELECT COUNT(1)
	INTO v_Count
	FROM dba_users
	WHERE username = v_Model_UserName;
		
	IF v_Count = 0 THEN
		--Raise an error if model user does not exist and we have not been asked to skip under that condition
		IF v_Skip_If_Model_User_Missing = 'N' THEN
			RAISE_APPLICATION_ERROR(-20205, 'Model_User: ' || NVL(v_Model_UserName, '[UNSPECIFIED]') || ' does not exist. Cannot clone.');
		END IF;       
			 
	ELSE

		v_msg_cur_operation := 'Remove the target user if it already exists and if we have been asked to remove it..';
		-------------------------------------------
		IF v_Remove_Cloned_User_If_Exists = 'Y' THEN
			SELECT COUNT(1)
			INTO v_Count
			FROM dba_users
			WHERE username = v_Cloned_UserName;
			
			IF v_Count > 0 THEN
				EXECUTE IMMEDIATE 'DROP USER ' || v_Cloned_UserName || ' CASCADE';
			END IF;            
		END IF;
		
		--Ensure that all statements generaetd have a semicolan terminator
		dbms_metadata.set_transform_param(dbms_metadata.SESSION_TRANSFORM,'SQLTERMINATOR',TRUE);

		v_msg_cur_operation := 'Fetch the user creation DDL';
		-------------------------------------------
		SELECT REPLACE(TO_CHAR 
					(case 
						when ((select count(*)
							   from   dba_users
							   where  username = v_Model_UserName) > 0)
						then  dbms_metadata.get_ddl ('USER', v_Model_UserName) 
						--else  to_clob ('   -- Note: User not found!')
						else  to_clob (NULL)
						end )
			   , v_Model_UserName, v_Cloned_UserName)                                    
		INTO v_SQL
		FROM DUAL;
		
		--Eliminate the last semi-colon...we are using the regular "EXECUTE IMMEDIATE" instead of the execute_immediate function since, 
		--	the password may have semi-colons and they should not be tokenized
		SELECT REVERSE(
				SUBSTR(REVERSE(v_SQL), INSTR(REVERSE(v_SQL), ';')+1)
				  )                                         
		INTO v_SQL 
		FROM DUAL;

		v_msg_cur_operation := 'Execute - user creation DDL';
		EXECUTE IMMEDIATE v_SQL;


		v_msg_cur_operation := 'Set the cloned users password to be the same as model user';
		-------------------------------------------
		--http://askdba.org/weblog/2008/11/how-to-changerestore-user-password-in-11g/
		--http://laurentschneider.com/wordpress/2008/03/alter-user-identified-by-values-in-11g.html
		
		IF v_Retain_Same_Password = 'Y' THEN
			SELECT alter_ddl
			INTO v_SQL          
			FROM 
			(
				select 'alter user '||v_Cloned_UserName||' identified by values '''||password||''' ' AS alter_ddl from sys.user$ where spare4 is null and password is not null and name = v_Model_UserName
				union
				select 'alter user '||v_Cloned_UserName||' identified by values '''||spare4||';'||password||''' ' AS alter_ddl from sys.user$ where spare4 is  not null and password is not null and name = v_Model_UserName 
			);    

			v_msg_cur_operation := 'Execute - password reset DDL';
			EXECUTE IMMEDIATE v_SQL;
		END IF;        
		
		v_msg_cur_operation := 'Fetch the tablespace quota DDL';
		-------------------------------------------
		SELECT REPLACE(TO_CHAR 
					(case 
						when ((select count(*)
							   from   dba_ts_quotas
							   where  username = v_Model_UserName) > 0)
						then  dbms_metadata.get_granted_ddl( 'TABLESPACE_QUOTA', v_Model_UserName) 
						--else  to_clob ('   -- Note: No TS Quotas found!')
						else  to_clob (NULL)
						end) 
				, v_Model_UserName, v_Cloned_UserName)                     
		INTO v_SQL
		FROM DUAL;

		v_msg_cur_operation := 'Execute - tablespace quota DDL';
		IF LTRIM(RTRIM(v_SQL)) IS NOT NULL THEN
			SELECT COUNT(1)
			INTO v_Count
			FROM v$instance
			WHERE version NOT LIKE '9%'; --Not 9i
			
			IF v_Count = 1 THEN
				--Eliminate the last '/'...we are using the regular "EXECUTE IMMEDIATE" instead of the execute_immediate function
				SELECT REVERSE(
						SUBSTR(REVERSE(v_SQL), INSTR(REVERSE(v_SQL), '/')+1)
						  )                                         
				INTO v_SQL 
				FROM DUAL;
				execute immediate(v_SQL);
			ELSE
				execute_immediate(v_SQL);
			END IF;
		END IF;                    
					

		v_msg_cur_operation := 'Fetch the role grants DDL';
		-------------------------------------------
		SELECT REPLACE(TO_CHAR 
					(case 
						when ((select count(*)
							   from   dba_role_privs
							   where  grantee = v_Model_UserName) > 0)
						then  dbms_metadata.get_granted_ddl ('ROLE_GRANT', v_Model_UserName) 
						--else  to_clob ('   -- Note: No granted Roles found!')
						else  to_clob (NULL)
						end )
				, v_Model_UserName, v_Cloned_UserName)                     
		INTO v_SQL
		FROM DUAL;

		v_msg_cur_operation := 'Execute - role grants DDL';
		execute_immediate(v_SQL);
		
		v_msg_cur_operation := 'If there are roles granted to user, fetch the default roles for user (will generate statement to make all other roles non-default)';
		-------------------------------------------
		IF v_SQL IS NOT NULL THEN
			SELECT REPLACE(TO_CHAR 
						(dbms_metadata.get_granted_ddl ('DEFAULT_ROLE', v_Model_UserName))
					, v_Model_UserName, v_Cloned_UserName)                     
			INTO v_SQL
			FROM DUAL;
			
			v_msg_cur_operation := 'Execute - the default roles for user';
			execute_immediate(v_SQL);
		END IF;
		
		v_msg_cur_operation := 'Fetch the system grants DDL';
		-------------------------------------------
		SELECT REPLACE(TO_CHAR
					(case 
						when ((select count(*)
							   from   dba_sys_privs
							   where  grantee = v_Model_UserName) > 0)
						then  dbms_metadata.get_granted_ddl ('SYSTEM_GRANT', v_Model_UserName) 
						--else  to_clob ('   -- Note: No System Privileges found!')
						else  to_clob (NULL)
						end )
				, v_Model_UserName, v_Cloned_UserName)                     
		INTO v_SQL
		FROM DUAL;

		v_msg_cur_operation := 'Execute - system grants DDL';
		execute_immediate(v_SQL);

		v_msg_cur_operation := 'Fetch the object grants DDL';
		-------------------------------------------
		SELECT REPLACE(TO_CHAR
					(case 
						when ((select count(*)
							   from   dba_tab_privs
							   where  grantee = v_Model_UserName) > 0)
						then  dbms_metadata.get_granted_ddl ('OBJECT_GRANT', v_Model_UserName) 
						--else  to_clob ('   -- Note: No Object Privileges found!')
						else  to_clob (NULL)
						end )
				, v_Model_UserName, v_Cloned_UserName)                     
		INTO v_SQL
		FROM DUAL;

		v_msg_cur_operation := 'Execute - object grants DDL';
		execute_immediate(v_SQL);
			   

	END IF;
	
EXCEPTION   
	WHEN OTHERS THEN
		v_err_cd := -20205;
		v_sqlerrm := 'Error occured:' ||
								CHR(13) || 'When: ' || v_msg_cur_operation ||
								CHR(13) || SQLCODE || SQLERRM;
		RAISE_APPLICATION_ERROR(v_err_cd, v_sqlerrm);
	
END;