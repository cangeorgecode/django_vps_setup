# django_vps_setup
How I host multiple Django apps on the same Linode running Ubuntu, say I have two apps - problem_bank and phone_repair

## Tips before we get into it
- Avoid symbols in nomenclature
- Run ``` python manage.py runserver ``` to check for errors with the django application
- Also, bear in mind that my file strucutre is problem_bank/proj/wsgi.py (Bear this in mind for gunicorn service file)
- When you run gunicorn, you should get a /var/www/django_app/problem_bank.sock file - check that it exists
- You might have installed packages from npm. Install these before running ```python manage.py tailwind start```
- ⚠️ If you have any .env files and they are not in the repo, it might cause an issue

## Installing gunicorn and nginx
- Git clone the django projects into Linode   
- Install requirements.txt of both projects in the same venv (not sure what the advantages or disadvantages are, need to look into it)
- Pip install gunicorn   
- Install nginx using this guide: https://www.linode.com/docs/guides/use-nginx-reverse-proxy/#install-nginx

## Configure gunicorn service file 
- You need a gunicorn service file for each app at /etc/systemd/system/problem_bank_gunicorn.service
- The /var/www/django_app/<app_name>.sock file will be created on its own

Gunicorn service file template
```
[Unit]
Description=Gunicorn instance to serve phone-repair
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=/var/www/django_app/phone-repair
ExecStart=/var/www/django_app/djangoenv/bin/gunicorn --access-logfile - --workers 3 --bind unix:/var/www/django_app/phone-repair.sock proj.wsgi:application

[Install]
WantedBy=multi-user.target
```

## Configure Nginx files
- Each application needs it own nginx config at /etc/nginx/sites-available/phone_repair and /etc/nginx/sites-avialable/problem_bank
```
server {
    listen 80;
    server_name phone-repair.example.com;

    location / {
        include proxy_params;
        proxy_pass http://unix:/var/www/django_app/phone-repair.sock;
    }
}
```
- You will still need an nginx config file, like a master file at /etc/nginx/conf.d/nginx.conf
```
include /etc/nginx/sites-enabled/*;
```

## Enable and start gunicorn services
```
sudo systemctl start phone-repair_gunicorn
sudo systemctl enable phone-repair_gunicorn
sudo systemctl start problem-bank_gunicorn
sudo systemctl enable problem-bank_gunicorn
```

## Enable, test and restart nginx sites
```
sudo ln -s /etc/nginx/sites-available/phone-repair /etc/nginx/sites-enabled
sudo ln -s /etc/nginx/sites-available/problem-bank /etc/nginx/sites-enabled
sudo nginx -t
sudo systemctl restart nginx
```

## Set up SSL for the domain
- Follow this guide to install certbot: https://www.linode.com/docs/guides/enabling-https-using-certbot-with-nginx-on-debian/
- But stop just before this command ``` sudo certbox --nginx ``` and do this instead
```
sudo certbot --nginx -d buildwebsite.io -d www.buildwebsite.io -d sumtingwong.me -d www.sumtingwong.me
```


## Debug
- If there's an error, check the followings
- Check gunicorn services
```
sudo systemctl status phone-repair_gunicorn
sudo systemctl status problem-bank_gunicorn
```

- Check nginx log
```
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/www/django_app/phone-repair/gunicorn.log
sudo tail -f /var/www/django_app/problem-bank/gunicorn.log
```

- Test gunicorn manually
```
cd /var/www/django_app/problem-bank
source /var/www/django_app/djangoenv/bin/activate
gunicorn --access-logfile - --workers 3 --bind unix:/var/www/django_app/problem-bank.sock problem-bank.wsgi:application
```

- If you've made changes to the service files, do this
```
sudo systemctl daemon-reload
sudo systemctl start problem-bank_gunicorn
sudo systemctl enable problem-bank_gunicorn
sudo systemctl start phone-repair_gunicorn
sudo systemctl enable phone-repair_gunicorn
```

## If you've updated content
git pull the content into your project folder first   
```
sudo systemctl restart phone-repair_gunicorn
sudo systemctl restart problem-bank_gunicorn
sudo systemctl reload nginx
```


## If you've removed a website, deleted the .sock file in the django_app/

Remove the file from the /etc/nginx/sites-enabled/<file>
```
sudo rm /etc/nginx/sites-enabled/dj_boilerplate_landing

# Check that the remaining configs are valid:
sudo nginx -t 

sudo systemctl reload nginx
```

