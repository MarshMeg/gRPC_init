rm init.sh
rm -rf init README .git
echo "" > README.md

git init
git remote add $1