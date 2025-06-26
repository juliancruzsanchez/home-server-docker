# echo Creating user...
# useradd

# echo Building file structure...
# mkdir persist-data

# echo Creating .env file from template...
# cp default.env .env

# echo Generating keys...
# ./scripts/generateKeys.sh

echo -----
echo Let\'s setup the environment file for suite!
echo -----
echo What domain root are you hosting your servers on?
echo Each service will run on a subdomain on that root.
echo -----
read -p "Enter root domain (ie. google.com): " ROOT_DOMAIN
clear
echo Domain set to: $ROOT_DOMAIN
echo -----
echo Next let\'s setup your logins!
echo -----
read -p "Enter your desired database username for all containers: " DB_USER
read -p "Enter your desired database password: " DB_PASS
echo 
read -p "Enter your email address for SSL: " EMAIL
echo 
read -p "Enter your desired admin username: " ADMIN_USER
read -p "Enter your desired admin password: " ADMIN_PASS
echo 
